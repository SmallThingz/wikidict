//! End-to-end bundle test: Lua/templates execute before data blobs are published.
const std = @import("std");
const expander = @import("bundle_expander.zig");
const encoder = @import("encoder");

const source =
    "==English==\n===Noun===\n{{forms-alias|mouse}}\n" ++
    "# A small rodent.\n{{Template:Template:nested}}\n{{nested}}\n{{T:nested}}\n" ++
    "{{:SharedAlias}}\n{{WT:Sandbox}}\n" ++
    "{{User:Fixture/Forms|word=mouse}}\n" ++
    "{{#categorytree:Integration categories|mode=pages}}\n" ++
    "# Missing transclusions: {{User:Absent}} / {{:Absent article}} / {{Category:Absent}}\n" ++
    "# Styled kanji: '''<span class=\"Jpan\" lang=\"ja\">兇</span>''' / '''<span lang=\"ja\">[[:凶#Japanese|凶]]</span>'''\n" ++
    "# Title magic: {{SUBJECTSPACE:Wiktionary talk:Sandbox}} / {{TALKSPACE:WT:Sandbox}}\n" ++
    "# Foreign parser aliases: {{#استدعاء:IntegrationExports|ok}} / {{#لو:yes|wrong Arabic if|bad}} / {{نط:10}}\n" ++
    "# Parser functions: {{#time:Y M d|2013-3-31 +8 days}} / {{#formatdate:2010-01-02|dmy}} / {{#sub:αβγ|-1}} / {{#iferror:{{#expr:bogus}}|ERR|OK}}\n" ++
    "# Synth fork: {{#invoke:IntegrationSynth|run|forked}}\n" ++
    "# Pure fork: {{#invoke:IntegrationPureDataProbe|run}}\n" ++
    "# Legacy varargs: {{#invoke:IntegrationLegacyVarargs|run}}\n" ++
    "# Captured fork: {{#invoke:IntegrationCapturedProbe|run}}\n" ++
    "# Repair recovery: {{repair-parent|x=term&lt;t:gloss&gt;}}\n" ++
    "# Graceful Lua error: {{#invoke:IntegrationForms|fail_probe}}\n" ++
    "# Missing export recovery: {{#iferror:{{#invoke:IntegrationExports|absent}}|ERR|BAD}} / {{#iferror:{{#invoke:IntegrationExports|value}}|ERR|BAD}} / {{#iferror:{{#invoke:IntegrationExports|callable}}|ERR|BAD}}\n" ++
    "# Preserved invoke boundary: A{{#invoke:IntegrationExports|absent}}B; next {{#invoke:IntegrationExports|ok}}\n" ++
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
const legacy_vararg_source =
    \\local export = {}
    \\_G.arg = 'module-global'
    \\assert(arg == 'module-global')
    \\local function pack(first, ...) return arg end
    \\local function two_fixed(first, second, ...) return arg end
    \\local function shadow_parameter(arg, ...) return arg end
    \\local function capture(...)
    \\    local function getter() return arg end
    \\    return getter
    \\end
    \\local function shadow_local(...)
    \\    local saved = arg
    \\    local arg = 'body-local'
    \\    return saved, arg
    \\end
    \\local function modern(...)
    \\    local first = ...
    \\    return arg, first
    \\end
    \\local function suppressed(...)
    \\    if false then return ... end
    \\    return arg
    \\end
    \\local function nested(...)
    \\    local function inner(...) return ... end
    \\    assert(inner('inner') == 'inner')
    \\    return arg
    \\end
    \\local function factory(...)
    \\    local function rebind(value) arg = value end
    \\    local function get() return arg end
    \\    return rebind, get
    \\end
    \\function export.run()
    \\    local empty = pack()
    \\    assert(type(empty) == 'table' and empty.n == 0 and next(empty) == 'n')
    \\    assert(two_fixed('only-one').n == 0)
    \\    local holes = pack('fixed', 'extra', nil, nil)
    \\    assert(holes.n == 3 and holes[1] == 'extra' and holes[2] == nil and holes[3] == nil)
    \\    assert(pack('fixed', 'extra') ~= pack('fixed', 'extra'))
    \\    local shadowed = shadow_parameter('named-arg', 'extra')
    \\    assert(shadowed.n == 1 and shadowed[1] == 'extra')
    \\    local getter = capture('captured', nil)
    \\    local captured = getter()
    \\    assert(captured.n == 2 and captured[1] == 'captured' and getter() == captured)
    \\    local saved, local_value = shadow_local('saved')
    \\    assert(saved.n == 1 and saved[1] == 'saved' and local_value == 'body-local')
    \\    local absent, first = modern('first', 'second')
    \\    assert(absent == nil and first == 'first' and suppressed('extra') == nil)
    \\    assert(nested('outer').n == 1 and nested('outer')[1] == 'outer')
    \\    local rebind, get = factory('before')
    \\    local initial = get()
    \\    assert(initial.n == 1 and initial[1] == 'before')
    \\    rebind('after')
    \\    assert(get() == 'after' and initial[1] == 'before')
    \\    local mt = {__index = function(...) return arg[1].stored .. arg[2] end}
    \\    assert(setmetatable({stored='receiver:'}, mt).missing == 'receiver:missing')
    \\    local mt_one = {__index = function(self, ...) return self.stored .. arg[1] end}
    \\    assert(setmetatable({stored='one:'}, mt_one).missing == 'one:missing')
    \\    local old_select, old_table = select, table
    \\    select = function() error('mutable select must not implement arg') end
    \\    table = {}
    \\    local independent = pack('fixed', 'extra', nil)
    \\    select, table = old_select, old_table
    \\    assert(independent.n == 2 and independent[1] == 'extra')
    \\    -- Pinned AF Skripnutsgoed.tag_text bold path: tag_attr has no ... expression.
    \\    local function class_attr(classes)
    \\        table.insert(classes, 1, 'Latn')
    \\        return 'class="' .. table.concat(classes, ' ') .. '"'
    \\    end
    \\    local function tag_attr(...)
    \\        return class_attr(arg) .. ' lang="eo"'
    \\    end
    \\    local rendered = '<b ' .. tag_attr() .. '>reĝo</b>'
    \\    assert(rendered == '<b class="Latn" lang="eo">reĝo</b>')
    \\    assert(_G.arg == 'module-global')
    \\    return 'legacy varargs verified'
    \\end
    \\return export
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
        .{ .title = "Template:نط:10", .ns = 10, .id = 31, .body = "English ordinary namespace template" },
        .{ .title = "Module:IntegrationForms", .ns = 828, .id = 1, .body = module_source },
        .{ .title = "Module:IntegrationLegacyVarargs", .ns = 828, .id = 32, .body = legacy_vararg_source },
        .{ .title = "Module:IntegrationExports", .ns = 828, .id = 30, .body = "return {ok=function() return 'OK' end, value=17, callable=setmetatable({}, {__call=function() return 'BAD' end})}" },
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

fn verifyFixture(h: *Harness, verifier: []const u8, root: []const u8, expected_error: ?[]const u8) ![]const u8 {
    const result = try std.process.run(h.a, h.io, .{
        .argv = &.{ verifier, root },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
        .timeout = (std.Io.Timeout{ .duration = .{ .raw = .fromSeconds(30), .clock = .awake } }).toDeadline(h.io),
    });
    const expected_exit: u8 = if (expected_error != null) 1 else 0;
    if (result.term != .exited or result.term.exited != expected_exit) {
        std.debug.print("blob verifier fixture failed: {any}, expected {d}\n{s}\n{s}\n", .{ result.term, expected_exit, result.stdout, result.stderr });
        return error.ChildFailed;
    }
    if (expected_error) |name| try h.require(std.mem.indexOf(u8, result.stderr, name) != null, name);
    h.checks += 1;
    return result.stderr;
}

fn unclassifiedLanguageProbe(h: *Harness, pipeline: []const u8, verifier: []const u8, bin: []const u8, dir: []const u8) !void {
    const format = encoder.blob_format;
    const catalog = encoder.blob_catalog;
    const root = try std.fs.path.join(h.a, &.{ dir, "unclassified-dictionary" });
    const dump = try std.fs.path.join(h.a, &.{ dir, "unclassified.xml" });
    const namespaces = try std.fs.path.join(h.a, &.{ dir, "unclassified-namespaces.tsv" });
    const languages = try std.fs.path.join(h.a, &.{ dir, "unclassified-languages.tsv" });
    const magic = try std.fs.path.join(h.a, &.{ dir, "unclassified-magic-words.tsv" });
    try std.Io.Dir.cwd().writeFile(h.io, .{
        .sub_path = namespaces,
        .data = "# wikidict-namespace-registry-v1\n# wiki\tarwiktionary\n# dump-date\t20261001\n# content-language\tar\n" ++
            "0\t\t\tfirst-letter\t0\t1\t0\twikitext\tmain\tentries\n" ++
            "10\tقالب\tTemplate\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\ttemplates\n" ++
            "14\tتصنيف\tCategory\tfirst-letter\t1\t0\t0\twikitext\tcompile_only\tcategories\n" ++
            "828\tوحدة\tModule\tcase-sensitive\t1\t0\t0\tScribunto\tcompile_only\tmodules\n",
    });
    try std.Io.Dir.cwd().writeFile(h.io, .{
        .sub_path = languages,
        .data = "# wikidict-language-registry-v2\n# content-language\tar\n# mediawiki\nar\tالعربية\tar\tArabic\tara\n# iso-639-3\n",
    });
    try std.Io.Dir.cwd().writeFile(h.io, .{
        .sub_path = magic,
        .data = "# wikidict-magic-words-v2\n# wiki\tarwiktionary\n# dump-date\t20261001\n# content-language\tar\n" ++
            "invoke\t0\tاستدعاء\ninvoke\t0\tinvoke\nif\t0\tلو\nif\t0\tif\n" ++
            "ns\t0\tنط:\nns\t0\tNS:\nuc\t0\tكبير:\nuc\t0\tUC:\n" ++
            "displaytitle\t1\tDISPLAYTITLE\ndisplaytitle\t1\tعرض_العنوان\n" ++
            "defaultsort\t1\tDEFAULTSORT:\ndefaultsort\t1\tترتيب_افتراضي:\n",
    });
    try writePages(h.io, h.a, dump, &.{
        .{ .title = "mixed", .ns = 0, .id = 1, .body = "{{DISPLAYTITLE:''mixed''}}{{ترتيب_افتراضي:sort-key}}\n==العربية==\n# Known Arabic definition.\n" ++
            "# Localized parser: {{localized-wrapper|passed}}\n" ++
            "# Namespace and case aliases: {{نط:10}} / {{كبير:abc}}\n" ++
            "# Sensitive misses: {{displaytitle:wrong}} / {{defaultsort:wrong}}\n" ++
            "=={{اللغة|Fixture unknown language}}==\n===Noun===\n# Isolated unknown definition.\n" },
        .{ .title = "unknown-only", .ns = 0, .id = 2, .body = "=={{اللغة|Fixture unknown language}}==\n# Second isolated definition.\n" },
        .{ .title = "قالب:اللغة", .ns = 10, .id = 3, .body = "{{{1|}}}" },
        .{ .title = "قالب:localized-wrapper", .ns = 10, .id = 4, .body = "{{#لو:{{{1|}}}|{{#استدعاء:AliasProbe|run|{{{1|}}}}}|{{unselected-loop}}}}" },
        .{ .title = "قالب:unselected-loop", .ns = 10, .id = 5, .body = "{{unselected-loop}}" },
        .{ .title = "قالب:displaytitle:wrong", .ns = 10, .id = 6, .body = "ordinary displaytitle template" },
        .{ .title = "قالب:defaultsort:wrong", .ns = 10, .id = 7, .body = "ordinary defaultsort template" },
        .{ .title = "وحدة:AliasProbe", .ns = 828, .id = 8, .body = "return {run=function(frame) " ++
            "assert(frame.args[1] == 'passed'); " ++
            "local nested = frame:callParserFunction{name='#استدعاء',args={'AliasTarget','run',x='native'}}; " ++
            "assert(nested == 'nested-native'); " ++
            "return 'localized native ' .. frame.args[1] .. '; ' .. nested end}" },
        .{ .title = "وحدة:AliasTarget", .ns = 828, .id = 9, .body = "return {run=function(frame) return 'nested-' .. frame.args.x end}" },
    });
    _ = try h.run(&.{ pipeline, dump, root, "--namespace-registry-snapshot", namespaces, "--language-registry-snapshot", languages, "--magic-words-snapshot", magic, "--llvm-workers", "1", "--page-workers", "1" }, 0);
    const verified = try verifyFixture(h, verifier, root, null);
    try h.require(std.mem.indexOf(u8, verified, "verified compiled blobs: language_blobs=2 language_records=3 ") != null, "language-kind totals include retained unclassified records");
    try h.require(std.mem.indexOf(u8, verified, "unverified language data: blobs=1 records=2\n") != null, "verifier separately reports unverified records");

    const inventory = try h.run(&.{ bin, "languages", "--root", root, "--format", "json" }, 0);
    var inventory_json = try std.json.parseFromSlice(std.json.Value, h.a, inventory, .{});
    defer inventory_json.deinit();
    const object = inventory_json.value.object;
    try h.require(object.get("heading_count").?.integer == 2 and object.get("language_count").?.integer == 1 and object.get("unverified_count").?.integer == 1, "reader distinguishes known languages from the unclassified bucket");
    var known_found = false;
    var unverified_found = false;
    for (object.get("accounting").?.array.items) |item| {
        const row = item.object;
        if (std.mem.eql(u8, row.get("heading").?.string, "Unclassified")) {
            unverified_found = true;
            try h.require(row.get("code").?.string.len == 0 and std.mem.eql(u8, row.get("classification").?.string, "unverified") and row.get("records").?.integer == 2, "reserved bucket keeps an empty code and unverified classification");
        } else {
            known_found = true;
            try h.require(std.mem.eql(u8, row.get("heading").?.string, "العربية") and std.mem.eql(u8, row.get("code").?.string, "ar") and std.mem.eql(u8, row.get("classification").?.string, "language") and row.get("records").?.integer == 1, "known Arabic language metadata remains verified");
        }
    }
    try h.require(known_found and unverified_found, "both language classifications are present");
    const known = try h.run(&.{ bin, "lookup", "mixed", "--root", root, "--language", "العربية", "--details" }, 0);
    try h.require(std.mem.indexOf(u8, known, "Known Arabic definition.") != null and std.mem.indexOf(u8, known, "Isolated unknown definition.") == null, "an unresolved explicit declaration never inherits the previous language");
    try h.require(std.mem.indexOf(u8, known, "Localized parser: localized native passed; nested-native") != null, "localized invoke works through a parameterized lazy template and the compiled Lua frame API");
    try h.require(std.mem.indexOf(u8, known, "Namespace and case aliases: قالب / ABC") != null, "localized no-hash parser aliases retain captured trailing-colon semantics");
    try h.require(std.mem.indexOf(u8, known, "Sensitive misses: ordinary displaytitle template / ordinary defaultsort template") != null, "sensitive alias misses do not fall through to case-insensitive English parser functions");
    const unknown = try h.run(&.{ bin, "lookup", "mixed", "--root", root, "--language", "Unclassified", "--details" }, 0);
    try h.require(std.mem.indexOf(u8, unknown, "Isolated unknown definition.") != null and std.mem.indexOf(u8, unknown, "Fixture unknown language") != null and std.mem.indexOf(u8, unknown, "Known Arabic definition.") == null, "unclassified lookup preserves the exact unknown heading and its own definition");

    const fallback_path = try std.fs.path.join(h.a, &.{ root, "fallback-pages.jsonl" });
    const fallback_bytes = try std.Io.Dir.cwd().readFileAlloc(h.io, fallback_path, h.a, .limited(4096));
    var lines = std.mem.tokenizeScalar(u8, fallback_bytes, '\n');
    var fallback_count: usize = 0;
    var mixed_reported = false;
    var only_reported = false;
    while (lines.next()) |line| {
        var parsed = try std.json.parseFromSlice(std.json.Value, h.a, line, .{});
        defer parsed.deinit();
        const row = parsed.value.object;
        const title = row.get("title").?.string;
        if (std.mem.eql(u8, title, "mixed")) mixed_reported = true else if (std.mem.eql(u8, title, "unknown-only")) only_reported = true else return error.UnexpectedFallback;
        const reasons = row.get("reasons").?.array.items;
        try h.require(row.get("namespace").?.integer == 0 and reasons.len == 1 and std.mem.eql(u8, reasons[0].string, "unresolved_language_heading"), "unclassified records retain their precise fallback diagnostic");
        fallback_count += 1;
    }
    try h.require(fallback_count == 2 and mixed_reported and only_reported, "every isolated page is reported without losing content");

    var filename: [catalog.language_blob_filename_len]u8 = undefined;
    const unclassified_path = try std.fs.path.join(h.a, &.{ root, catalog.language_directory, catalog.languageBlobFilename("Unclassified", &filename) });
    const complete = try std.Io.Dir.cwd().readFileAlloc(h.io, unclassified_path, h.a, .limited(1024 * 1024));
    const blob = try format.inspect(complete);
    var records = blob.iterator();
    const record = (try records.next()) orelse return error.MissingUnclassifiedRecord;
    const corrupted_payload = try h.a.dupe(u8, record.payload);
    corrupted_payload[0] ^= 0xff;
    const Rejection = struct { name: []const u8, heading: []const u8, catalog_heading: ?[]const u8 = null, corrupt: bool = false, expected: []const u8 };
    const rejections = [_]Rejection{
        .{ .name = "ordinary-empty-code", .heading = "English", .expected = "UnverifiedLanguage" },
        .{ .name = "lowercase-reserved-name", .heading = "unclassified", .expected = "UnverifiedLanguage" },
        .{ .name = "spaced-reserved-name", .heading = "Unclassified ", .expected = "UnverifiedLanguage" },
        .{ .name = "catalog-mismatch", .heading = "Unclassified", .catalog_heading = "English", .expected = "UnexpectedLanguageBlob" },
        .{ .name = "corrupt-unclassified-payload", .heading = "Unclassified", .corrupt = true, .expected = "InvalidPresentation" },
    };
    for (rejections) |rejection| {
        const rejected_root = try std.fs.path.join(h.a, &.{ dir, rejection.name });
        try std.Io.Dir.cwd().createDirPath(h.io, try std.fs.path.join(h.a, &.{ rejected_root, catalog.language_directory }));
        const heading = rejection.catalog_heading orelse rejection.heading;
        const manifest = try std.fmt.allocPrint(h.a, "{s}\n{s}\n", .{ catalog.manifest_header, heading });
        try std.Io.Dir.cwd().writeFile(h.io, .{ .sub_path = try std.fs.path.join(h.a, &.{ rejected_root, catalog.manifest_filename }), .data = manifest });
        const metadata = try format.buildLanguageMetadataAlloc(h.a, "", rejection.heading);
        const bytes = try format.buildAlloc(h.a, .language, metadata, &.{.{ .title = record.title, .payload = if (rejection.corrupt) corrupted_payload else record.payload }});
        const path = try std.fs.path.join(h.a, &.{ rejected_root, catalog.language_directory, catalog.languageBlobFilename(heading, &filename) });
        try std.Io.Dir.cwd().writeFile(h.io, .{ .sub_path = path, .data = bytes });
        _ = try verifyFixture(h, verifier, rejected_root, rejection.expected);
    }
    _ = try verifyFixture(h, verifier, root, null);
}

fn structuredWikibaseProbe(h: *Harness, pipeline: []const u8, verifier: []const u8, bin: []const u8, dir: []const u8) !void {
    const root = try std.fs.path.join(h.a, &.{ dir, "wikibase-dictionary" });
    const dump = try std.fs.path.join(h.a, &.{ dir, "wikibase.xml" });
    const namespaces = try std.fs.path.join(h.a, &.{ dir, "wikibase-namespaces.tsv" });
    const languages = try std.fs.path.join(h.a, &.{ dir, "wikibase-languages.tsv" });
    const entities = try std.fs.path.join(h.a, &.{ dir, "wikibase-entities.tsv" });
    const terms = try std.fs.path.join(h.a, &.{ dir, "wikibase-entity-terms.tsv" });
    const fallbacks = try std.fs.path.join(h.a, &.{ dir, "wikibase-language-fallbacks.tsv" });
    const messages = try std.fs.path.join(h.a, &.{ dir, "wikibase-interface-messages.tsv" });
    const site_info = try std.fs.path.join(h.a, &.{ dir, "wikibase-siteinfo.raw.json" });
    try std.Io.Dir.cwd().writeFile(h.io, .{ .sub_path = site_info, .data = "{\"query\":{\"general\":{\"wikiid\":\"arwiktionary\",\"lang\":\"ar\",\"server\":\"//ar.wiktionary.org\"}}}" });
    try std.Io.Dir.cwd().writeFile(h.io, .{
        .sub_path = namespaces,
        .data = "# wikidict-namespace-registry-v1\n# wiki\tarwiktionary\n# dump-date\t20261001\n# content-language\tar\n" ++
            "0\t\t\tfirst-letter\t0\t1\t0\twikitext\tmain\tentries\n" ++
            "8\tميدياويكي\tMediaWiki\tfirst-letter\t1\t0\t0\twikitext\tcompile_only\tstandard_build_input\n" ++
            "10\tقالب\tTemplate\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\ttemplates\n" ++
            "14\tتصنيف\tCategory\tfirst-letter\t1\t0\t0\twikitext\tcompile_only\tcategories\n" ++
            "828\tوحدة\tModule\tcase-sensitive\t1\t0\t0\tScribunto\tcompile_only\tmodules\n",
    });
    try std.Io.Dir.cwd().writeFile(h.io, .{
        .sub_path = languages,
        .data = "# wikidict-language-registry-v2\n# content-language\tar\n# mediawiki\nar\tالعربية\tar\tArabic\tara\n# iso-639-3\n",
    });
    const entity_identity = "# wiki=arwiktionary\n# date=20261001\n# content-language=ar\n# repository=https://www.wikidata.org\n";
    const lexeme = "{\"id\":\"L100\",\"type\":\"lexeme\",\"schemaVersion\":2,\"language\":\"Q13955\",\"lexicalCategory\":\"Q24905\"," ++
        "\"lemmas\":{\"ar\":{\"language\":\"ar\",\"value\":\"كَتَبَ\"}}," ++
        "\"claims\":{\"P5920\":[{\"rank\":\"normal\",\"mainsnak\":{\"snaktype\":\"value\",\"property\":\"P5920\",\"datatype\":\"wikibase-lexeme\",\"datavalue\":{\"type\":\"wikibase-entityid\",\"value\":{\"entity-type\":\"lexeme\",\"id\":\"L101\"}}}}]," ++
        "\"P5186\":[{\"rank\":\"normal\",\"mainsnak\":{\"snaktype\":\"value\",\"property\":\"P5186\",\"datatype\":\"wikibase-item\",\"datavalue\":{\"type\":\"wikibase-entityid\",\"value\":{\"entity-type\":\"item\",\"numeric-id\":400,\"id\":\"Q400\"}}}}]," ++
        "\"P9295\":[{\"rank\":\"normal\",\"mainsnak\":{\"snaktype\":\"value\",\"property\":\"P9295\",\"datatype\":\"wikibase-item\",\"datavalue\":{\"type\":\"wikibase-entityid\",\"value\":{\"entity-type\":\"item\",\"numeric-id\":200,\"id\":\"Q200\"}}}," ++
        "\"qualifiers\":{\"P1\":[{\"snaktype\":\"somevalue\",\"property\":\"P1\",\"datatype\":\"string\"}]},\"qualifiers-order\":[\"P1\"]," ++
        "\"references\":[{\"hash\":\"fixture-reference\",\"snaks\":{\"P2\":[{\"snaktype\":\"novalue\",\"property\":\"P2\",\"datatype\":\"string\"}]},\"snaks-order\":[\"P2\"]}]}," ++
        "{\"rank\":\"deprecated\",\"mainsnak\":{\"snaktype\":\"value\",\"property\":\"P9295\",\"datatype\":\"wikibase-item\",\"datavalue\":{\"type\":\"wikibase-entityid\",\"value\":{\"entity-type\":\"item\",\"numeric-id\":202,\"id\":\"Q202\"}}}}," ++
        "{\"rank\":\"preferred\",\"mainsnak\":{\"snaktype\":\"value\",\"property\":\"P9295\",\"datatype\":\"wikibase-item\",\"datavalue\":{\"type\":\"wikibase-entityid\",\"value\":{\"entity-type\":\"item\",\"numeric-id\":201,\"id\":\"Q201\"}}}}]}," ++
        "\"forms\":[{\"id\":\"L100-F1\",\"grammaticalFeatures\":[\"Q1350145\",\"Q2\"],\"representations\":{\"ar\":{\"language\":\"ar\",\"value\":\"كَاتِب\"}},\"claims\":{}}]," ++
        "\"senses\":[{\"id\":\"L100-S1\",\"glosses\":{\"ar\":{\"language\":\"ar\",\"value\":\"دوّن\"}},\"claims\":{}}]}";
    const root_lexeme = "{\"id\":\"L101\",\"type\":\"lexeme\",\"schemaVersion\":2,\"language\":\"Q13955\",\"lexicalCategory\":\"Q20136634\",\"lemmas\":{\"ar\":{\"language\":\"ar\",\"value\":\"كتب\"}},\"claims\":{}}";
    const arabic_item = "{\"id\":\"Q200\",\"type\":\"item\",\"schemaVersion\":2," ++
        "\"labels\":{\"ar\":{\"language\":\"ar\",\"value\":\"متعد\"},\"en\":{\"language\":\"en\",\"value\":\"transitive\"}}," ++
        "\"descriptions\":{\"ar\":{\"language\":\"ar\",\"value\":\"وصف عربي\"}},\"aliases\":{\"ar\":[{\"language\":\"ar\",\"value\":\"اسم بديل\"}]}," ++
        "\"sitelinks\":{\"arwiktionary\":{\"site\":\"arwiktionary\",\"title\":\"متعد\",\"badges\":[]},\"enwiktionary\":{\"site\":\"enwiktionary\",\"title\":\"transitive\",\"badges\":[]}},\"claims\":{}}";
    const fallback_item = "{\"id\":\"Q201\",\"type\":\"item\",\"schemaVersion\":2,\"labels\":{\"en\":{\"language\":\"en\",\"value\":\"ambitransitive\"}},\"descriptions\":{\"en\":{\"language\":\"en\",\"value\":\"English description\"}},\"claims\":{}}";
    try std.Io.Dir.cwd().writeFile(h.io, .{
        .sub_path = entities,
        .data = "# wikidict-wikibase-entities-v1\n" ++ entity_identity ++ "# profile=complete-entities-v1\n" ++
            "L100\tE\tL100\t" ++ lexeme ++ "\nL101\tE\tL101\t" ++ root_lexeme ++
            "\nL102\tE\tL100\t" ++ lexeme ++ "\nL404\tM\t\t\nQ200\tE\tQ200\t" ++ arabic_item ++
            "\nQ201\tE\tQ201\t" ++ fallback_item ++
            "\nQ202\tE\tQ202\t{\"id\":\"Q202\",\"type\":\"item\",\"schemaVersion\":2,\"labels\":{\"en\":{\"language\":\"en\",\"value\":\"deprecated fixture\"}},\"claims\":{}}\n",
    });
    try std.Io.Dir.cwd().writeFile(h.io, .{
        .sub_path = terms,
        .data = "# wikidict-wikibase-entity-terms-v1\n" ++ entity_identity ++ "# profile=resolved-default-terms-v1\n" ++
            "L100\tE\tL100\t{\"label\":null,\"description\":null}\n" ++
            "L101\tE\tL101\t{\"label\":null,\"description\":null}\n" ++
            "L102\tE\tL100\t{\"label\":null,\"description\":null}\nL404\tM\t\t\n" ++
            "Q200\tE\tQ200\t{\"label\":{\"language\":\"ar\",\"value\":\"متعد\"},\"description\":{\"language\":\"ar\",\"value\":\"وصف عربي\"}}\n" ++
            "Q201\tE\tQ201\t{\"label\":{\"language\":\"en\",\"value\":\"ambitransitive\",\"source-language\":\"en\"},\"description\":{\"language\":\"en\",\"value\":\"English description\"}}\n",
    });
    try std.Io.Dir.cwd().writeFile(h.io, .{
        .sub_path = fallbacks,
        .data = "# wikidict-language-fallbacks-v1\n# wiki\tarwiktionary\n# dump-date\t20261001\n# content-language\tar\n# mode\tstrict\n" ++
            "ar\t\nen\t\nfr\tde\tit\n",
    });
    try std.Io.Dir.cwd().writeFile(h.io, .{
        .sub_path = messages,
        .data = "# wikidict-interface-messages-v1\n# wiki\tarwiktionary\n# dump-date\t20261001\n# content-language\tar\n" ++
            "ar\tcomma-separator\tV\t، \nar\tand\tV\tو\nar\tword-separator\tV\t \n" ++
            "ar\twikibase-client-data-bridge-bailout-suggestion-go-to-repo-button\tV\tعرض {{WBREPONAME}}\n" ++
            "ar\tfixture-message\tV\tعربي $1 / $2\n" ++
            "en\tfixture-message\tV\tEnglish $1 / $2\n" ++
            "ar\tfixture-escaped\tV\tfirst\\nsecond\\tpart\\\\end\n" ++
            "ar\tfixture-missing\tM\n",
    });
    const module =
        \\local function fails(fn, fragment)
        \\  local ok, err = pcall(fn)
        \\  assert(not ok, 'expected explicit failure')
        \\  if fragment then assert(string.find(tostring(err), fragment, 1, true), tostring(err)) end
        \\end
        \\local site_configuration = mw.loadData('وحدة:SiteServerConfiguration')
        \\assert(site_configuration.code == 'ar' and site_configuration.server == '//ar.wiktionary.org')
        \\return {run=function(frame)
        \\  assert(mw.site.server == '//ar.wiktionary.org' and rawget(mw.site, 'server') == mw.site.server)
        \\  local found_server = false
        \\  for key, value in pairs(mw.site) do if key == 'server' then found_server = value == '//ar.wiktionary.org' end end
        \\  assert(found_server)
        \\  local entity = mw.wikibase.getEntity('L100')
        \\  assert(entity.id == 'L100' and entity.schemaVersion == 2 and entity.type == 'lexeme')
        \\  assert(entity.language == 'Q13955' and entity.lexicalCategory == 'Q24905')
        \\  assert(entity.lemmas.ar.value == 'كَتَبَ' and entity.lemmas.ar.language == 'ar')
        \\  assert(entity.forms[0] == nil and #entity.forms == 1)
        \\  local form = entity.forms[1]
        \\  assert(form.id == 'L100-F1' and form.grammaticalFeatures[1] == 'Q1350145' and form.grammaticalFeatures[2] == 'Q2')
        \\  assert(form.representations.ar.value == 'كَاتِب' and next(form.claims) == nil)
        \\  assert(entity.senses[1].id == 'L100-S1' and entity.senses[1].glosses.ar.value == 'دوّن')
        \\  assert(entity:getId() == 'L100' and entity:getLanguage() == 'Q13955' and entity:getLexicalCategory() == 'Q24905')
        \\  local sense_getter = entity[frame.args[2] or 'getSenses']
        \\  local senses1, senses2 = sense_getter(entity), entity:getSenses()
        \\  assert(senses1 ~= senses2 and senses1[1] == senses2[1] and senses1[1] == entity.senses[1])
        \\  local sense = senses1[1]
        \\  assert(sense:getId() == 'L100-S1')
        \\  local gloss, gloss_language = sense.getGloss(sense)
        \\  assert(gloss == 'دوّن' and gloss_language == 'ar' and sense:getGloss('en') == nil)
        \\  local glosses = sense:getGlosses()
        \\  glosses[1][1] = 'changed pair'
        \\  assert(sense:getGloss('ar') == 'دوّن')
        \\  assert(next(sense:getAllStatements('P5831')) == nil)
        \\  assert(mw.wikibase.getEntity('L100-S1'):getGloss() == 'دوّن')
        \\  assert(next(mw.wikibase.getAllStatements('L100-S1', 'P5831')) == nil)
        \\  assert(mw.wikibase.getEntity('L100-S999') == nil)
        \\  fails(function() mw.wikibase.getEntity('L999-S1') end, 'Wikibase entity snapshot missing entity=L999')
        \\  local forms1, forms2 = entity:getForms(), entity:getForms()
        \\  assert(forms1 ~= forms2 and forms1[1] == forms2[1] and forms1[1] == entity.forms[1])
        \\  assert(forms1[1]:getGrammaticalFeatures() == form.grammaticalFeatures)
        \\  local representation, representation_language = forms1[1]:getRepresentation()
        \\  assert(representation == 'كَاتِب' and representation_language == 'ar')
        \\  local representations = forms1[1]:getRepresentations()
        \\  representations[1][1] = 'changed representation pair'
        \\  assert(form:getRepresentation('ar') == 'كَاتِب')
        \\  assert(mw.wikibase.getEntity('L100-F1'):getRepresentation('ar') == 'كَاتِب')
        \\  local root_id = entity.claims.P5920[1].mainsnak.datavalue.value.id
        \\  assert(root_id == 'L101' and entity.claims.P5186[1].mainsnak.datavalue.value.id == 'Q400')
        \\  local root = mw.wikibase.getEntity(root_id)
        \\  local lemmas = root:getLemmas()
        \\  assert(lemmas[0] == nil and #lemmas == 1 and lemmas[1][1] == 'كتب' and lemmas[1][2] == 'ar')
        \\  lemmas[1][1] = 'changed pair'
        \\  assert(root:getLemmas()[1][1] == 'كتب' and root.lemmas.ar.value == 'كتب')
        \\  assert(mw.wikibase.getEntity('L102').id == 'L100')
        \\  assert(root:getId() == 'L101' and #root:getSenses() == 0 and #root:getForms() == 0)
        \\  local object_statements = entity:getAllStatements('P9295')
        \\  object_statements[1].mainsnak.datavalue.value.id = 'Q997'
        \\  object_statements[1].references[1].hash = 'changed local reference'
        \\  local object_again = entity:getAllStatements('P9295')
        \\  assert(object_again[1].mainsnak.datavalue.value.id == 'Q200')
        \\  assert(object_again[1].references[1].hash == 'fixture-reference')
        \\  fails(function() object_again[1].qualifiers.P1 = {} end)
        \\  local statements = mw.wikibase.getAllStatements('L100', 'P9295')
        \\  assert(statements[0] == nil and #statements == 3)
        \\  assert(statements[1].rank == 'normal' and statements[2].rank == 'deprecated' and statements[3].rank == 'preferred')
        \\  assert(statements[1].mainsnak.datavalue.value['numeric-id'] == 200)
        \\  assert(statements[1].qualifiers.P1[1].snaktype == 'somevalue')
        \\  assert(statements[1]['qualifiers-order'][1] == 'P1')
        \\  assert(statements[1].references[1].hash == 'fixture-reference' and statements[1].references[1].snaks.P2[1].snaktype == 'novalue')
        \\  fails(function() entity.claims.P9295 = {} end)
        \\  fails(function() statements[1].qualifiers.P1 = {} end)
        \\  fails(function() statements[1].references[1] = {} end)
        \\  local labels = {}
        \\  for _, statement in ipairs(statements) do
        \\    if statement.rank ~= 'deprecated' then
        \\      local label, language = mw.wikibase.getLabelWithLang(statement.mainsnak.datavalue.value.id)
        \\      table.insert(labels, label .. ':' .. language)
        \\    end
        \\  end
        \\  assert(table.concat(labels, ',') == 'متعد:ar,ambitransitive:en')
        \\  entity.lemmas.ar.value = 'changed lemma'
        \\  form.representations.ar.value = 'changed form'
        \\  entity.claims.P9295[1].mainsnak.datavalue.value.id = 'Q999'
        \\  assert(statements[1].mainsnak.datavalue.value.id == 'Q200')
        \\  statements[1].mainsnak.datavalue.value.id = 'Q998'
        \\  statements[2].rank = 'normal'
        \\  local fresh = mw.wikibase.getEntity('L100')
        \\  assert(fresh.lemmas.ar.value == 'كَتَبَ' and fresh.forms[1].representations.ar.value == 'كَاتِب')
        \\  assert(fresh.claims.P9295[1].mainsnak.datavalue.value.id == 'Q200')
        \\  local fresh_statements = mw.wikibase.getAllStatements('L100', 'P9295')
        \\  assert(fresh_statements[1].mainsnak.datavalue.value.id == 'Q200' and fresh_statements[2].rank == 'deprecated')
        \\  local absent_property = mw.wikibase.getAllStatements('L100', 'P999')
        \\  assert(next(absent_property) == nil)
        \\  absent_property[1] = 'local mutation'
        \\  assert(next(mw.wikibase.getAllStatements('L100', 'P999')) == nil)
        \\  local item = mw.wikibase.getEntity('Q200')
        \\  fails(function() item.labels.ar = {} end)
        \\  fails(function() item.descriptions.ar = {} end)
        \\  fails(function() item.aliases.ar = {} end)
        \\  fails(function() item.sitelinks.arwiktionary = {} end)
        \\  assert(item:getId() == 'Q200' and item:getSitelink() == 'متعد' and item:getSitelink('enwiktionary') == 'transitive')
        \\  assert(item:getSitelink('frwiktionary') == nil)
        \\  assert(mw.wikibase.getGlobalSiteId() == 'arwiktionary')
        \\  assert(mw.wikibase.getSitelink('Q200') == 'متعد')
        \\  assert(mw.wikibase.getSitelink('Q200', 'enwiktionary') == 'transitive')
        \\  assert(mw.wikibase.getSitelink('Q200', 'frwiktionary') == nil)
        \\  item.labels.ar.value = 'changed label'
        \\  item.sitelinks.arwiktionary.title = 'changed sitelink'
        \\  assert(item:getSitelink() == 'changed sitelink')
        \\  assert(mw.wikibase.getLabelByLang('Q200', 'ar') == 'متعد' and mw.wikibase.getSitelink('Q200') == 'متعد')
        \\  assert(mw.wikibase.getLabel('Q201') == 'ambitransitive')
        \\  assert(mw.wikibase.getLabelByLang('Q201', 'ar') == nil and mw.wikibase.getLabelByLang('Q201', 'en') == 'ambitransitive')
        \\  local fallback_item = mw.wikibase.getEntity('Q201')
        \\  assert(fallback_item.labels.ar.value == 'ambitransitive' and fallback_item.labels.ar.language == 'en')
        \\  assert(fallback_item.labels.ar['source-language'] == 'en' and fallback_item.descriptions.ar.value == 'English description')
        \\  assert(mw.wikibase.getLabelByLang('Q201', 'ar') == nil)
        \\  assert(mw.wikibase.getEntity('L404') == nil and next(mw.wikibase.getAllStatements('L404', 'P5920')) == nil)
        \\  local no_label, no_language = mw.wikibase.getLabelWithLang('L404')
        \\  assert(no_label == nil and no_language == nil)
        \\  fails(function() mw.wikibase.getEntity('L999') end, 'Wikibase entity snapshot missing entity=L999')
        \\  fails(function() mw.wikibase.getLabelWithLang('Q202') end, 'Wikibase entity-term snapshot missing entity=Q202')
        \\  assert(mw.wikibase.getEntity('L100').lemmas.ar.value == 'كَتَبَ')
        \\  local content = mw.language.getContentLanguage()
        \\  assert(content:getCode() == 'ar')
        \\  assert(#mw.language.getFallbacksFor('ar', mw.language.FALLBACK_STRICT) == 0)
        \\  assert(#mw.language.getFallbacksFor('en') == 0)
        \\  local chain = mw.language.getFallbacksFor('fr')
        \\  assert(table.concat(chain, ',') == 'de,it,en')
        \\  table.insert(chain, 1, 'fr')
        \\  chain[2] = 'changed fallback'
        \\  assert(table.concat(mw.language.getFallbacksFor('fr'), ',') == 'de,it,en')
        \\  assert(table.concat(mw.language.new('fr'):getFallbackLanguages(mw.language.FALLBACK_STRICT), ',') == 'de,it')
        \\  local object_chain = content:getFallbackLanguages()
        \\  assert(#object_chain == 1 and object_chain[1] == 'en')
        \\  table.insert(object_chain, 1, 'ar')
        \\  assert(table.concat(content:getFallbackLanguages(), ',') == 'en')
        \\  fails(function() mw.language.getFallbacksFor('es') end)
        \\  local comma = mw.message.new('Comma-separator'):plain()
        \\  local word_separator = mw.message.new('Word-separator')
        \\  assert(comma == '، ' and mw.message.new('And'):plain() == 'و')
        \\  assert(word_separator:plain() == ' ' and word_separator:exists() and not word_separator:isBlank())
        \\  assert(mw.message.new('fixture-message', 'value', 7):plain() == 'عربي value / 7')
        \\  assert(mw.message.new('fixture-message', 'value', 7):inLanguage('en'):plain() == 'English value / 7')
        \\  assert(mw.message.new('fixture-escaped'):plain() == 'first\nsecond\tpart\\end')
        \\  local missing_message = mw.message.new('fixture-missing')
        \\  assert(not missing_message:exists() and missing_message:plain() == '⧼fixture-missing⧽')
        \\  fails(function() mw.message.new('fixture-uncaptured'):plain() end)
        \\  local edit = mw.message.new('Wikibase-client-data-bridge-bailout-suggestion-go-to-repo-button'):plain()
        \\  assert(edit == 'عرض {{WBREPONAME}}')
        \\  edit = string.gsub(edit, '{{WBREPONAME}}', 'ويكي بيانات')
        \\  return '<table><caption>Captured Wikibase ' .. frame.args[1] .. '</caption><tr><td>' ..
        \\    fresh.lemmas.ar.value .. comma .. root.lemmas.ar.value .. word_separator:plain() .. mw.message.new('And'):plain() ..
        \\    word_separator:plain() .. fresh.forms[1].representations.ar.value .. '</td></tr><tr><td>' ..
        \\    table.concat(labels, ',') .. '</td></tr><tr><td>' .. edit .. '</td></tr></table>'
        \\end, raise=function() error('intentional fixture Lua failure') end}
    ;
    try writePages(h.io, h.a, dump, &.{
        .{ .title = "entity-first", .ns = 0, .id = 1, .body = "==العربية==\n{{#invoke:EntityProbe|run|first}}\n# Suppressed error: {{#iferror:{{#invoke:EntityProbe|raise}}|recovered}}\n" },
        .{ .title = "entity-second", .ns = 0, .id = 2, .body = "==العربية==\n{{#invoke:EntityProbe|run|second}}\n" },
        .{ .title = "entity-visible-error", .ns = 0, .id = 3, .body = "==العربية==\n# Before visible error: {{#invoke:EntityProbe|raise}}; after visible error.\n" },
        .{ .title = "وحدة:EntityProbe", .ns = 828, .id = 4, .body = module },
        // Exact unconditional CS1/Configuration rev1097951 lines1419-1422.
        .{ .title = "وحدة:SiteServerConfiguration", .ns = 828, .id = 5, .body = "local lang_obj = mw.language.getContentLanguage()\n" ++
            "local this_wiki_code = lang_obj:getCode();\n" ++
            "if string.match (mw.site.server, 'wikidata') then\n" ++
            "  this_wiki_code = mw.getCurrentFrame():callParserFunction('int', {'lang'});\n" ++
            "end\nreturn {code=this_wiki_code, server=mw.site.server}" },
    });
    _ = try h.run(&.{
        pipeline,                           dump,                            root,
        "--namespace-registry-snapshot",    namespaces,                      "--language-registry-snapshot",
        languages,                          "--wikibase-entities-snapshot",  entities,
        "--wikibase-entity-terms-snapshot", terms,                           "--language-fallbacks-snapshot",
        fallbacks,                          "--interface-messages-snapshot", messages,
        "--site-info-snapshot",             site_info,                       "--llvm-workers",
        "1",                                "--page-workers",                "1",
    }, 0);
    _ = try verifyFixture(h, verifier, root, null);
    const cases = [_]struct { title: []const u8, caption: []const u8 }{
        .{ .title = "entity-first", .caption = "Captured Wikibase first" },
        .{ .title = "entity-second", .caption = "Captured Wikibase second" },
    };
    for (cases) |case| {
        const output = try h.run(&.{ bin, "lookup", case.title, "--root", root, "--language", "العربية", "--details" }, 0);
        try h.require(std.mem.indexOf(u8, output, case.caption) != null, "structured Wikibase assertions execute on each page through the native worker");
        try h.require(std.mem.indexOf(u8, output, "كَتَبَ، كتب و كَاتِب") != null, "full lexeme, root and form fields survive native compilation and presentation encoding");
        try h.require(std.mem.indexOf(u8, output, "متعد:ar,ambitransitive:en") != null, "statement order and actual resolved-label languages survive publication");
        try h.require(std.mem.indexOf(u8, output, "عرض ويكي بيانات") != null, "plain captured messages preserve placeholders until Lua replaces them");
        try h.require(std.mem.indexOf(u8, output, "Lua error") == null and std.mem.indexOf(u8, output, "#invoke") == null, "snapshot API failures are caught explicitly and never replace the successful fixture");
        if (std.mem.eql(u8, case.title, "entity-first"))
            try h.require(std.mem.indexOf(u8, output, "Suppressed error: recovered") != null, "iferror suppresses a source-raised Scribunto failure before presentation compilation");
    }
    const visible_error = try h.run(&.{ bin, "lookup", "entity-visible-error", "--root", root, "--language", "العربية", "--details" }, 0);
    try h.require(std.mem.indexOf(u8, visible_error, "Before visible error:") != null and
        std.mem.indexOf(u8, visible_error, "intentional fixture Lua failure") != null and
        std.mem.indexOf(u8, visible_error, "; after visible error.") != null, "a visible source-raised Lua error preserves the diagnostic text and surrounding definition");
    const fallback_bytes = try std.Io.Dir.cwd().readFileAlloc(h.io, try std.fs.path.join(h.a, &.{ root, "fallback-pages.jsonl" }), h.a, .limited(4096));
    var fallback_lines = std.mem.tokenizeScalar(u8, fallback_bytes, '\n');
    var fallback_count: usize = 0;
    while (fallback_lines.next()) |line| {
        var parsed = try std.json.parseFromSlice(std.json.Value, h.a, line, .{});
        defer parsed.deinit();
        const row = parsed.value.object;
        try h.require(std.mem.eql(u8, row.get("title").?.string, "entity-visible-error"), "successful entity pages and suppressed errors remain clean");
        const reasons = row.get("reasons").?.array.items;
        try h.require(row.get("namespace").?.integer == 0 and reasons.len == 1 and
            std.mem.eql(u8, reasons[0].string, "rendered_lua_error"), "a retained Scribunto error has an explicit build-time quality diagnostic");
        fallback_count += 1;
    }
    try h.require(fallback_count == 1, "the visible Lua error is counted once in fallback accounting");
}

fn hasSemanticLink(value: std.json.Value, target: []const u8, label: []const u8) bool {
    switch (value) {
        .object => |object| {
            if (object.get("target")) |destination| {
                if (object.get("text")) |text| {
                    if (destination == .string and text == .string and
                        std.mem.eql(u8, destination.string, target) and std.mem.eql(u8, text.string, label)) return true;
                }
            }
            for (object.values()) |child| {
                if (hasSemanticLink(child, target, label)) return true;
            }
        },
        .array => |array| for (array.items) |child| {
            if (hasSemanticLink(child, target, label)) return true;
        },
        else => {},
    }
    return false;
}

fn contentLanguageCaseProbe(h: *Harness, pipeline: []const u8, verifier: []const u8, bin: []const u8, dir: []const u8) !void {
    const case_module =
        \\return {run=function(frame)
        \\    local content = mw.getContentLanguage()
        \\    assert(content:getCode() == frame.args[1])
        \\    assert(content:uc('äbc') == 'ÄBC' and content:lc('ÄBC') == 'äbc')
        \\    assert(content:ucfirst('wǽre') == 'Wǽre' and content:lcfirst('WǽRE') == 'wǽRE')
        \\    assert(content:ucfirst('selfstandige naamwoorde') == 'Selfstandige naamwoorde')
        \\    assert(mw.ustring.upper('äbc') == 'ÄBC' and mw.ustring.lower('ÄBC') == 'äbc')
        \\    local af, ang = mw.language.new('af'), mw.language.new('ang')
        \\    assert(af:ucfirst('selfstandige naamwoorde') == 'Selfstandige naamwoorde')
        \\    assert(ang:lcfirst(ang:uc('da')) == 'dA' and ang:ucfirst('wǽre') == 'Wǽre')
        \\    local tr = mw.language.new('tr')
        \\    assert(tr:uc('istanbul') == 'ISTANBUL' and tr:lc('ISTANBUL') == 'istanbul')
        \\    assert(tr:ucfirst('istanbul') == 'İstanbul' and tr:ucfirst('ısparta') == 'Isparta')
        \\    assert(tr:lcfirst('Istanbul') == 'ıstanbul' and tr:lcfirst('İzmir') == 'izmir')
        \\    local az = mw.language.new('az')
        \\    assert(az:ucfirst('istanbul') == 'İstanbul' and az:lcfirst('Istanbul') == 'istanbul')
        \\    local kaa = mw.language.new('kaa')
        \\    assert(kaa:ucfirst('ıraq') == 'Íraq' and kaa:lcfirst('Íraq') == 'ıraq')
        \\    assert(mw.language.new('crh'):ucfirst('istanbul') == 'İstanbul')
        \\    assert(mw.language.new('az-latn'):ucfirst('istanbul') == 'Istanbul')
        \\    return 'content language ' .. content:getCode() .. ' case methods verified'
        \\end}
    ;
    const editions = [_]struct { code: []const u8, heading: []const u8, iso3: []const u8, template_ns: []const u8, title: []const u8 }{
        .{ .code = "af", .heading = "Afrikaans", .iso3 = "afr", .template_ns = "Sjabloon", .title = "koppelvlak" },
        .{ .code = "ang", .heading = "Englisc", .iso3 = "ang", .template_ns = "Bysen", .title = "fire" },
    };
    for (editions) |edition| {
        const prefix = try std.fmt.allocPrint(h.a, "{s}-content-case", .{edition.code});
        const root = try std.fs.path.join(h.a, &.{ dir, prefix });
        const dump = try std.fmt.allocPrint(h.a, "{s}/{s}.xml", .{ dir, prefix });
        const namespaces = try std.fmt.allocPrint(h.a, "{s}/{s}-namespaces.tsv", .{ dir, prefix });
        const languages = try std.fmt.allocPrint(h.a, "{s}/{s}-languages.tsv", .{ dir, prefix });
        try std.Io.Dir.cwd().writeFile(h.io, .{
            .sub_path = namespaces,
            .data = try std.fmt.allocPrint(h.a, "# wikidict-namespace-registry-v1\n# wiki\t{s}wiktionary\n# dump-date\t20261001\n# content-language\t{s}\n" ++
                "0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n" ++
                "10\t{s}\tTemplate\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\ttemplates\n" ++
                "14\tCategory\tCategory\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\tcategories\n" ++
                "828\tModule\tModule\tcase-sensitive\t1\t0\t0\tScribunto\tcompile_only\tmodules\n", .{ edition.code, edition.code, edition.template_ns }),
        });
        try std.Io.Dir.cwd().writeFile(h.io, .{
            .sub_path = languages,
            .data = try std.fmt.allocPrint(h.a, "# wikidict-language-registry-v2\n# content-language\t{s}\n# mediawiki\n{s}\t{s}\t{s}\t{s}\n# iso-639-3\n", .{
                edition.code, edition.code, edition.heading, edition.code, edition.iso3,
            }),
        });
        if (std.mem.eql(u8, edition.code, "af")) {
            // Pinned koppelvlak -> Sjabloon:A, plus the paired first-case
            // operations used by Sjabloon:H. Keep the nested PAGENAME call.
            try writePages(h.io, h.a, dump, &.{
                .{ .title = "koppelvlak", .ns = 0, .id = 1, .body = "==Afrikaans==\n# {{A|Koppelvlak}}\n# {{H|selfstandige naamwoord}}\n# {{#invoke:CaseProbe|run|af}}\n" },
                .{ .title = "Sjabloon:A", .ns = 10, .id = 2, .body = "[[#Afrikaans (af)|{{ucfirst:{{PAGENAME}}}}]]" },
                .{ .title = "Sjabloon:H", .ns = 10, .id = 3, .body = "<includeonly>[[{{lcfirst:{{{1|}}}}}|{{ucfirst:{{{1|}}}}}]]</includeonly>" },
                .{ .title = "Module:CaseProbe", .ns = 828, .id = 4, .body = case_module },
            });
        } else {
            // Reduce the pinned cardinal -> context/tag and wikipedia
            // wrappers to their case expressions while preserving parameters.
            try writePages(h.io, h.a, dump, &.{
                .{ .title = "fire", .ns = 0, .id = 1, .body = "==Englisc==\n# Cardinal case: {{cardinal|lang=da}}\n# {{#invoke:CaseProbe|run|ang}}\n" },
                .{ .title = "Bysen:cardinal", .ns = 10, .id = 2, .body = "{{context/tag|cardinal|lang={{{lang}}}}}" },
                .{ .title = "Bysen:context/tag", .ns = 10, .id = 3, .body = "{{lcfirst:{{uc:{{{lang}}}}}}}" },
                .{ .title = "Module:CaseProbe", .ns = 828, .id = 4, .body = case_module },
                .{ .title = "wǽre", .ns = 0, .id = 5, .body = "==Englisc==\n# Wikipedia title: {{wikipedia}}\n" },
                .{ .title = "Bysen:wikipedia", .ns = 10, .id = 6, .body = "{{{1|{{ucfirst:{{PAGENAME}}}}}}}" },
            });
        }
        _ = try h.run(&.{ pipeline, dump, root, "--namespace-registry-snapshot", namespaces, "--language-registry-snapshot", languages, "--llvm-workers", "1", "--page-workers", "1" }, 0);
        _ = try verifyFixture(h, verifier, root, null);
        const word = try h.run(&.{ bin, "lookup", edition.title, "--root", root, "--language", edition.heading, "--details" }, 0);
        const witness = try std.fmt.allocPrint(h.a, "content language {s} case methods verified", .{edition.code});
        try h.require(std.mem.indexOf(u8, word, witness) != null, "native content-language and language-object case methods use inherited base rules and explicit first-character overrides");
        if (std.mem.eql(u8, edition.code, "af")) {
            const exported = try h.run(&.{ bin, "export", edition.title, "--root", root, "--language", edition.heading }, 0);
            var parsed = try std.json.parseFromSlice(std.json.Value, h.a, exported, .{});
            defer parsed.deinit();
            try h.require(hasSemanticLink(parsed.value, "#Afrikaans (af)", "Koppelvlak"), "Afrikaans A template preserves its fragment target and uppercases the nested current page name");
            try h.require(hasSemanticLink(parsed.value, "selfstandige naamwoord", "Selfstandige naamwoord"), "Afrikaans H template compiles both lower-first targets and upper-first link labels");
        } else {
            try h.require(std.mem.indexOf(u8, word, "Cardinal case: dA") != null, "Old English cardinal wrappers expand nested full uppercase and first lowercase calls");
            const wikipedia = try h.run(&.{ bin, "lookup", "wǽre", "--root", root, "--language", edition.heading, "--details" }, 0);
            try h.require(std.mem.indexOf(u8, wikipedia, "Wikipedia title: Wǽre") != null, "Old English default parameters preserve the current page title through ucfirst");
        }
        const fallbacks = try std.Io.Dir.cwd().readFileAlloc(h.io, try std.fs.path.join(h.a, &.{ root, "fallback-pages.jsonl" }), h.a, .limited(4096));
        try h.require(std.mem.trim(u8, fallbacks, " \t\r\n").len == 0, "Afrikaans and Old English case paths publish without expansion errors or visible Lua error fallbacks");
    }
}

fn japaneseParserAliasProbe(h: *Harness, pipeline: []const u8, verifier: []const u8, bin: []const u8, dir: []const u8) !void {
    const root = try std.fs.path.join(h.a, &.{ dir, "japanese-dictionary" });
    const dump = try std.fs.path.join(h.a, &.{ dir, "japanese.xml" });
    const namespaces = try std.fs.path.join(h.a, &.{ dir, "japanese-namespaces.tsv" });
    const languages = try std.fs.path.join(h.a, &.{ dir, "japanese-languages.tsv" });
    const magic = try std.fs.path.join(h.a, &.{ dir, "japanese-magic-words.tsv" });
    try std.Io.Dir.cwd().writeFile(h.io, .{
        .sub_path = namespaces,
        .data = "# wikidict-namespace-registry-v1\n# wiki\tjawiktionary\n# dump-date\t20261001\n# content-language\tja\n" ++
            "0\t\t\tfirst-letter\t0\t1\t0\twikitext\tmain\tentries\n" ++
            "10\tテンプレート\tTemplate\tcase-sensitive\t1\t0\t0\twikitext\tcompile_only\ttemplates\n" ++
            "14\tカテゴリ\tCategory\tfirst-letter\t1\t0\t0\twikitext\tcompile_only\tcategories\n",
    });
    try std.Io.Dir.cwd().writeFile(h.io, .{ .sub_path = languages, .data = "# wikidict-language-registry-v2\n# content-language\tja\n# mediawiki\nja\t日本語\tja\tjpn\n# iso-639-3\n" });
    try std.Io.Dir.cwd().writeFile(h.io, .{
        .sub_path = magic,
        // Register the insensitive parser alias first; the exact sensitive
        // title-function match must still win across the two function families.
        .data = "# wikidict-magic-words-v2\n# wiki\tjawiktionary\n# dump-date\t20261001\n# content-language\tja\n" ++
            "ns\t0\t名前空間:\nnamespace\t1\t名前空間\nns\t0\t空間：\n",
    });
    try writePages(h.io, h.a, dump, &.{.{ .title = "単語", .ns = 0, .id = 1, .body = "==日本語==\n# Cross-family collision: {{名前空間:Template:Child}}\n# Fullwidth namespace alias: {{空間：10}}\n" }});
    _ = try h.run(&.{ pipeline, dump, root, "--namespace-registry-snapshot", namespaces, "--language-registry-snapshot", languages, "--magic-words-snapshot", magic, "--llvm-workers", "1", "--page-workers", "1" }, 0);
    _ = try verifyFixture(h, verifier, root, null);
    const word = try h.run(&.{ bin, "lookup", "単語", "--root", root, "--language", "日本語", "--details" }, 0);
    try h.require(std.mem.indexOf(u8, word, "Cross-family collision: テンプレート") != null, "sensitive Japanese title alias wins over an insensitive parser alias");
    try h.require(std.mem.indexOf(u8, word, "Fullwidth namespace alias: テンプレート") != null, "captured fullwidth colon aliases resolve before native publication");
}

fn localizedEditionProbe(h: *Harness, pipeline: []const u8, verifier: []const u8, bin: []const u8, dir: []const u8) !void {
    const namespaces = @import("namespace_registry");
    const german_root = try std.fs.path.join(h.a, &.{ dir, "german-dictionary" });
    const german_xml = try std.fs.path.join(h.a, &.{ dir, "german.xml" });
    const german_ns = try std.fs.path.join(h.a, &.{ dir, "german-namespaces.tsv" });
    const german_languages = try std.fs.path.join(h.a, &.{ dir, "german-languages.tsv" });
    const german_magic = try std.fs.path.join(h.a, &.{ dir, "german-magic-words.tsv" });
    try std.Io.Dir.cwd().writeFile(h.io, .{ .sub_path = german_ns, .data = namespaces.german_test_fixture });
    try std.Io.Dir.cwd().writeFile(h.io, .{ .sub_path = german_languages, .data = "# wikidict-language-registry-v2\n# content-language\tde\n# mediawiki\nde\tDeutsch\tde\tdeu\n# iso-639-3\n" });
    // Collision precedence follows MediaWiki registration order, not TSV row order.
    try std.Io.Dir.cwd().writeFile(h.io, .{
        .sub_path = german_magic,
        .data = "# wikidict-magic-words-v1\n# wiki\tdewiktionary\n# dump-date\t20261001\n# content-language\tde\n" ++
            "pagename\t1\tSEITENNAME\npagename\t1\tPAGENAME\n" ++
            "pagename\t1\tCOLLISION\nbasepagename\t1\tCOLLISION\n" ++
            "basepagename\t1\tREVERSED_COLLISION\npagename\t1\tREVERSED_COLLISION\n",
    });
    const redirect_probe_source =
        \\return {run=function()
        \\    local target = require('Modul:i18n')
        \\    assert(target.wrapper_runs == 0 and package.loaded['Modul:I18n'] == nil)
        \\    local wrapper = require('Modul:WrapperChain')
        \\    assert(wrapper == target and target.wrapper_runs == 1)
        \\    assert(package.loaded['Modul:WrapperChain'] == wrapper)
        \\    assert(require('Modul:WrapperAlias') == wrapper)
        \\    assert(require('Modul:I18n') == wrapper and target.wrapper_runs == 1)
        \\    assert(require('Module:I18n') == wrapper and target.wrapper_runs == 1)
        \\    assert(package.loaded['Modul:I18n'] == wrapper)
        \\    assert(package.loaded['Modul:i18n'] == target)
        \\    local upper_override = {kind='upper override'}
        \\    package.loaded['Modul:I18n'] = upper_override
        \\    assert(require('Modul:I18n') == upper_override)
        \\    assert(require('Modul:i18n') == target)
        \\    package.loaded['Modul:I18n'] = wrapper
        \\    local lower_override = {kind='lower override'}
        \\    package.loaded['Modul:i18n'] = lower_override
        \\    assert(require('Modul:i18n') == lower_override)
        \\    assert(require('Modul:I18n') == wrapper and target.wrapper_runs == 1)
        \\    package.loaded['Modul:i18n'] = target
        \\    local cycle = require('Modul:CycleAlias')
        \\    assert(cycle.kind == 'compiled cycle' and cycle == require('Modul:CycleWrapper'))
        \\    local ok = pcall(require, 'Modul:RedirectCycleA')
        \\    assert(not ok)
        \\    ok = pcall(require, 'Modul:RedirectCycleB')
        \\    assert(not ok)
        \\    return 'case-sensitive wrapper lifecycle verified'
        \\end}
    ;
    try writePages(h.io, h.a, german_xml, &.{
        .{ .title = "Wort", .ns = 0, .id = 1, .body = "==Deutsch==\n===Substantiv===\n# {{:Template:Probe}}\n" ++
            "# Local title magic: {{SEITENNAME}} / {{PAGENAME}} / {{SEITENNAME:Vorlage:Other}} / {{SEITENNAME:{{MagicTarget}}}}\n" ++
            "# Template collisions: {{SEITENNAME|argument}} / {{PAGENAME|argument}} / {{Seitenname}} / {{FULLPAGENAME}}\n" },
        .{ .title = "Vorlage:Probe", .ns = 10, .id = 2, .body = "{{#in<!-- join -->voke:Probe|run}}" },
        .{ .title = "Modul:Probe", .ns = 828, .id = 3, .body = "local export = {}; function export.run(frame) " ++
            "assert(require('math') == math); local ns = mw.site.namespaces; " ++
            "assert(ns.Template.name == 'Vorlage' and ns.Module.name == 'Modul'); " ++
            "assert(ns.Rhymes == nil and ns[106].name == 'Reim'); " ++
            "assert(mw.title.new('Module:Data').prefixedText == 'Modul:Data'); " ++
            "local data = require('Module:Alias'); " ++
            "assert(mw.loadData('Modul:Data').word == data.word); " ++
            "package.loaded['Module:Alias'] = false; assert(require('Module:Alias') == false); " ++
            "return data.word .. '; ' .. require('Module:RedirectProbe').run() end; return export" },
        .{ .title = "Modul:Data", .ns = 828, .id = 4, .body = "return {word='localized native module'}" },
        .{ .title = "Modul:Alias", .ns = 828, .id = 5, .body = "#REDIRECT [[Module:Data]]", .redirect = "Module:Data" },
        .{ .title = "Modul:math", .ns = 828, .id = 6, .body = "return {wrong_builtin=true}" },
        .{ .title = "Flexion:Parent/Child", .ns = 108, .id = 7, .body = "Supplemental German inflection.\n" ++
            "Title collision: {{COLLISION}} / {{COLLISION:Vorlage:Parent/Child}}\n" ++
            "Reversed collision: {{REVERSED_COLLISION}} / {{REVERSED_COLLISION:Vorlage:Parent/Child}}\n" },
        .{ .title = "Modul:RedirectProbe", .ns = 828, .id = 8, .body = redirect_probe_source },
        .{ .title = "Modul:i18n", .ns = 828, .id = 9, .body = "return {kind='target', wrapper_runs=0}" },
        .{ .title = "Modul:I18n", .ns = 828, .id = 10, .model = "Scribunto", .redirect = "Module:i18n", .body = "local name = ...; assert(name == 'Modul:I18n'); local target = require('Modul:i18n'); target.wrapper_runs = target.wrapper_runs + 1; return target" },
        .{ .title = "Modul:WrapperAlias", .ns = 828, .id = 11, .redirect = "Module:I18n", .body = "#REDIRECT [[Module:I18n]]" },
        .{ .title = "Modul:WrapperChain", .ns = 828, .id = 12, .redirect = "Module:WrapperAlias", .body = "#REDIRECT [[Module:WrapperAlias]]" },
        .{ .title = "Modul:CycleWrapper", .ns = 828, .id = 13, .model = "Scribunto", .redirect = "Module:CycleAlias", .body = "return {kind='compiled cycle'}" },
        .{ .title = "Modul:CycleAlias", .ns = 828, .id = 14, .redirect = "Module:CycleWrapper", .body = "#REDIRECT [[Module:CycleWrapper]]" },
        .{ .title = "Modul:RedirectCycleA", .ns = 828, .id = 15, .redirect = "Module:RedirectCycleB", .body = "#REDIRECT [[Module:RedirectCycleB]]" },
        .{ .title = "Modul:RedirectCycleB", .ns = 828, .id = 16, .redirect = "Module:RedirectCycleA", .body = "#REDIRECT [[Module:RedirectCycleA]]" },
        .{ .title = "Vorlage:SEITENNAME", .ns = 10, .id = 17, .body = "localized-template-{{{1|default}}}" },
        .{ .title = "Vorlage:Seitenname", .ns = 10, .id = 18, .body = "case-sensitive-template" },
        .{ .title = "Vorlage:FULLPAGENAME", .ns = 10, .id = 19, .body = "unsupported-alias-template" },
        .{ .title = "Vorlage:MagicTarget", .ns = 10, .id = 20, .body = "Vorlage:Nested" },
        .{ .title = "Vorlage:PAGENAME", .ns = 10, .id = 21, .body = "english-template-{{{1|default}}}" },
    });
    _ = try h.run(&.{ pipeline, german_xml, german_root, "--namespace-registry-snapshot", german_ns, "--language-registry-snapshot", german_languages, "--magic-words-snapshot", german_magic, "--llvm-workers", "1", "--page-workers", "1", "--now-unix", "1791072000" }, 0);
    _ = try h.run(&.{ verifier, german_root }, 0);
    const word = try h.run(&.{ bin, "lookup", "Wort", "--root", german_root, "--language", "Deutsch", "--details" }, 0);
    try h.require(std.mem.indexOf(u8, word, "localized native module") != null, "localized templates, invokes, module aliases and raw package overrides survive native compilation");
    try h.require(std.mem.indexOf(u8, word, "case-sensitive wrapper lifecycle verified") != null, "compiled Scribunto redirect wrappers retain distinct identities, cached execution and independent package overrides");
    try h.require(std.mem.indexOf(u8, word, "Local title magic: Wort / Wort / Other / Nested") != null, "edition-local title magic resolves bare names and expanded colon parameters before native publication");
    try h.require(std.mem.indexOf(u8, word, "Template collisions: localized-template-argument / english-template-argument / case-sensitive-template / unsupported-alias-template") != null, "title aliases respect pipe arguments, exact case and the authoritative edition snapshot");
    const inflection = try h.run(&.{ bin, "lookup", "Flexion:Parent/Child", "--root", german_root, "--kind", "supplemental", "--details" }, 0);
    try h.require(std.mem.indexOf(u8, inflection, "Supplemental German inflection") != null, "custom German subject namespaces are retained");
    try h.require(std.mem.indexOf(u8, inflection, "Title collision: Parent/Child / Parent") != null, "bare and colon title collisions follow distinct MediaWiki registration orders");
    try h.require(std.mem.indexOf(u8, inflection, "Reversed collision: Parent/Child / Parent") != null, "reversing case-sensitive alias rows preserves native collision precedence");
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
            "# Foreign title alias: {{SEITENNAME}}\n" ++
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
        .{ .title = "Modèle:SEITENNAME", .ns = 10, .id = 16, .body = "French ordinary template" },
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
    try h.require(std.mem.indexOf(u8, french_word, "Foreign title alias: French ordinary template") != null, "German title aliases do not become global magic words in a different edition");
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
    try unclassifiedLanguageProbe(&h, pipeline, verifier, bin, dir);
    try structuredWikibaseProbe(&h, pipeline, verifier, bin, dir);
    try japaneseParserAliasProbe(&h, pipeline, verifier, bin, dir);
    try contentLanguageCaseProbe(&h, pipeline, verifier, bin, dir);
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
    const message_snapshot = try std.fs.path.join(a, &.{ dir, "interface-messages.tsv" });
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = message_snapshot,
        .data = "# wikidict-interface-messages-v1\n# wiki\tenwiktionary\n# dump-date\t20261001\n# content-language\ten\n" ++
            "en\tdefinitely-missing-message\tM\n",
    });
    const root = try std.fs.path.join(a, &.{ dir, "dictionary" });
    _ = try h.run(&.{ pipeline, dump, root, "--namespace-registry-snapshot", namespace_registry, "--category-tree-snapshot", category_snapshot, "--interface-messages-snapshot", message_snapshot, "--language-registry-snapshot", language_registry, "--llvm-workers", "1", "--page-workers", "2" }, 0);
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
    try h.require(std.mem.indexOf(u8, text, "Legacy varargs: legacy varargs verified") != null, "Lua 5.1 legacy vararg tables preserve scope, counts, closures and native AF bold-link behavior");
    try h.require(std.mem.indexOf(u8, text, "user-space inflection mouse") != null, "User namespace transclusion and relative child expand before publication");
    try h.require(std.mem.indexOf(u8, text, "User:Absent") != null and std.mem.indexOf(u8, text, "Absent article") != null and std.mem.indexOf(u8, text, "Category:Absent") != null, "missing transclusions in every namespace compile to semantic links");
    try h.require(std.mem.indexOf(u8, text, "private documentation") == null, "User namespace noinclude remains excluded");
    try h.require(std.mem.indexOf(u8, text, "{|") == null and std.mem.indexOf(u8, text, "templatestyles") == null, "wrapped wiki tables survive semantic encoding without source markup");
    try h.require(std.mem.indexOf(u8, text, "Forms from native Lua") != null, "template result is baked into data");
    try h.require(std.mem.indexOf(u8, text, "shared main transclusion") != null, "main-page redirect transclusion is baked into data");
    try h.require(std.mem.indexOf(u8, text, "project namespace transclusion") != null, "namespace-alias transclusion is baked into data");
    try h.require(std.mem.indexOf(u8, text, "Styled kanji: 兇 / 凶") != null, "emphasized HTML compiles to semantic styled text and links");
    try h.require(std.mem.indexOf(u8, text, "Title magic: Wiktionary / Wiktionary talk") != null, "title magic words are resolved before publication");
    try h.require(std.mem.indexOf(u8, text, "Foreign parser aliases: {{#استدعاء:IntegrationExports|ok}} / {{#لو:yes|wrong Arabic if|bad}} / English ordinary namespace template") != null, "Arabic parser aliases remain inert or ordinary templates in the English edition");
    try h.require(std.mem.indexOf(u8, text, "Parser functions: 2013 Apr 08 / 2 January 2010 / γ / ERR") != null, "corpus parser functions are baked into data");
    try h.require(std.mem.indexOf(u8, text, "Synth fork: synth:forked") != null, "synthesized roots materialize in fresh invoke contexts");
    try h.require(std.mem.indexOf(u8, text, "Pure fork: x") != null, "pure-data roots materialize independently in fresh invoke contexts");
    try h.require(std.mem.indexOf(u8, text, "Captured fork: captured:forked") != null, "synthesized callable roots rebuild scalar capture cells in fresh invoke contexts");
    try h.require(std.mem.indexOf(u8, text, "Repair recovery: repaired invoke") != null, "invalid-title invoke retries entity-escaped inline modifiers once");
    try h.require(std.mem.indexOf(u8, text, "Graceful Lua error: Lua error in Module:IntegrationForms: fixture failure") != null, "unrepaired Scribunto failures compile as inert error text");
    try h.require(std.mem.indexOf(u8, text, "Missing export recovery: ERR / ERR / ERR") != null, "missing and non-function Scribunto exports remain recoverable parser errors");
    try h.require(std.mem.indexOf(u8, text, "Preserved invoke boundary: ALua error in Module:IntegrationExports:") != null and std.mem.indexOf(u8, text, "B; next OK") != null, "an uncaught missing export preserves surrounding text and a later valid invoke succeeds");
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
