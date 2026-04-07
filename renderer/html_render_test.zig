const std = @import("std");
const html_render = @import("html_render.zig");
const generated_templates = @import("generated_template_runtime");
const generated = @import("generated_structure_tables");

const templateMatchesHtml = html_render.templateMatchesHtml;
const isStrictSupportedTemplateName = html_render.isStrictSupportedTemplateName;

fn renderEnglishSectionAlloc(allocator: std.mem.Allocator, source: []const u8) ![]html_render.RenderedSection {
    if (!html_render.hasGeneratedTemplateRuntime()) return error.SkipZigTest;
    return html_render.renderEnglishSectionAlloc(allocator, source);
}

fn renderEnglishSectionWithOptionsAlloc(
    allocator: std.mem.Allocator,
    source: []const u8,
    options: html_render.RenderOptions,
) ![]html_render.RenderedSection {
    if (!html_render.hasGeneratedTemplateRuntime()) return error.SkipZigTest;
    return html_render.renderEnglishSectionWithOptionsAlloc(allocator, source, options);
}

fn trimWikiWhitespace(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, " \t");
}

fn lineTemplateSampleAlloc(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\==English==
        \\===Noun===
        \\# {{{{{s}|en|alpha|beta}}}}
        \\
    , .{name});
}

fn translationTemplateSampleAlloc(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\==English==
        \\===Noun===
        \\# thing
        \\====Translations====
        \\{{{{trans-top|test}}}}
        \\* French: {{{{{s}|fr|alpha}}}}
        \\{{{{trans-bottom}}}}
        \\
    , .{name});
}

fn renderedSectionsHaveVisibleHtml(sections: []const html_render.RenderedSection) bool {
    for (sections) |section| {
        if (std.mem.trim(u8, section.html, " \t\r\n").len != 0) return true;
    }
    return false;
}

test "renderEnglishSectionAlloc renders part-of-speech senses without raw templates" {
    const source =
        \\==English==
        \\
        \\===Noun===
        \\{{en-noun}}
        \\# {{lb|en|physical}} A [[round]] object.
        \\## A [[ring]] worn on the finger.
        \\##: {{ux|en|a gold ring}}
        \\
        \\====Derived terms====
        \\{{col4|en|wedding ring|ring finger|signet ring}}
    ;

    const sections = try renderEnglishSectionAlloc(std.testing.allocator, source);
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 2), sections.len);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "<ol class=\"render-sense-list\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "A round object.") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "{{") == null);
    try std.testing.expect(std.mem.indexOf(u8, sections[1].html, "<ul class=\"render-term-grid\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[1].html, "wedding ring") != null);
}

test "renderEnglishSectionAlloc preserves comma grouped column terms as single items" {
    const source =
        \\==English==
        \\===Hyponyms===
        \\{{col4|en|pronouncing dictionary,pronunciation dictionary|rhyme dictionary,rhyming dictionary}}
    ;

    const sections = try renderEnglishSectionAlloc(std.testing.allocator, source);
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "pronouncing dictionary, pronunciation dictionary") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "rhyme dictionary, rhyming dictionary") != null);
}

test "renderEnglishSectionAlloc renders column qualifiers without leaking qq tags" {
    const source =
        \\==English==
        \\====Derived terms====
        \\{{col3|en|Thursdays<qq:adverb>|Thursday Island}}
    ;

    const sections = try renderEnglishSectionAlloc(std.testing.allocator, source);
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Thursdays") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "adverb") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "qq:adverb") == null);
}

test "renderEnglishSectionAlloc keeps coordinate-term group separators" {
    const source =
        \\==English==
        \\===Noun===
        \\# {{cot|en|near-antonym|;|coordinate term|cohyponym|;<!--fellow type of the same larger class, but not diametrically opposite-->|antiphrasis|;<!--intentionally discrepant meaning-->|near-synonym|parasynonym|plesionym|;<!--nearly the same-->}}
    ;

    const sections = try renderEnglishSectionAlloc(std.testing.allocator, source);
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "near-antonym") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "coordinate term") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "antiphrasis") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "; ") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "<!--") == null);
}

test "renderEnglishSectionAlloc expands known list templates used by coordinate terms" {
    const source =
        \\==English==
        \\====Coordinate terms====
        \\{{list:units of time/en}}
    ;
    const resolver = TestResolverContext{ .terms = &.{ "day", "month", "year", "week", "hour" } };

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{
        .link_resolver = .{
            .context = @ptrCast(&resolver),
            .resolve = resolveTestLink,
        },
    });
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "<ul class=\"render-term-grid\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "/entry/day") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "attosecond") != null);
}

test "renderEnglishSectionAlloc expands religious adherent list templates" {
    const source =
        \\==English==
        \\====Coordinate terms====
        \\{{list:religious adherents/en}}
    ;
    const resolver = TestResolverContext{ .terms = &.{ "Asatruar", "Christian", "Muslim", "Wiccan" } };

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{
        .link_resolver = .{
            .context = @ptrCast(&resolver),
            .resolve = resolveTestLink,
        },
    });
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "African traditionalist") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "<a href=\"/entry/Asatruar\">Asatruar</a>") != null);
}

test "renderEnglishSectionAlloc keeps multiline column sections with named args" {
    const source =
        \\==English==
        \\
        \\===Proper noun===
        \\# A month.
        \\
        \\====Derived terms====
        \\{{col3
        \\|en|December bride|Destroy Dick December
        \\|Decemberish
        \\|Decemberly
        \\|Decembrist
        \\|May-December
        \\}}
        \\
        \\====Related terms====
        \\{{col4
        \\|en|December effect
        \\|December solstice
        \\|May and December
        \\|title=Related terms of December
        \\}}
    ;

    const sections = try renderEnglishSectionAlloc(std.testing.allocator, source);
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 3), sections.len);
    try std.testing.expectEqualStrings("Derived terms", sections[1].title);
    try std.testing.expect(std.mem.indexOf(u8, sections[1].html, "December bride") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[1].html, "May-December") != null);
    try std.testing.expectEqualStrings("Related terms", sections[2].title);
    try std.testing.expect(std.mem.indexOf(u8, sections[2].html, "December effect") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[2].html, "May and December") != null);
}

test "renderEnglishSectionAlloc keeps hypernym column sections with titles" {
    const source =
        \\==English==
        \\
        \\===Noun===
        \\# A period of time.
        \\
        \\====Hypernyms====
        \\{{col4
        \\|en|time
        \\|week
        \\|month
        \\|year
        \\|title=Hypernyms of day
        \\}}
    ;

    const sections = try renderEnglishSectionAlloc(std.testing.allocator, source);
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 2), sections.len);
    try std.testing.expectEqualStrings("Hypernyms", sections[1].title);
    try std.testing.expect(std.mem.indexOf(u8, sections[1].html, "time") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[1].html, "year") != null);
}

test "renderEnglishSectionAlloc strips inline comments from column terms" {
    const source =
        \\==English==
        \\
        \\===Noun===
        \\# A weekday.
        \\
        \\====Hyponyms====
        \\{{col4|en
        \\|Alb Sunday
        \\|Hall' Sunday<!--sic-->
        \\|Sunday-go-to-meeting<!--adjective-->
        \\|Sundays<pos:adverb>
        \\}}
    ;

    const sections = try renderEnglishSectionAlloc(std.testing.allocator, source);
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 2), sections.len);
    try std.testing.expectEqualStrings("Hyponyms", sections[1].title);
    try std.testing.expect(std.mem.indexOf(u8, sections[1].html, "Hall' Sunday") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[1].html, "Sunday-go-to-meeting") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[1].html, "Sundays") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[1].html, "(adverb)") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[1].html, "sic") == null);
    try std.testing.expect(std.mem.indexOf(u8, sections[1].html, "adjective") == null);
    try std.testing.expect(std.mem.indexOf(u8, sections[1].html, "pos:adverb") == null);
}

test "renderEnglishSectionAlloc prefixes etymology lexemes with language names" {
    const source =
        \\==English==
        \\
        \\===Etymology===
        \\Related to {{m+|en|moon}}.
        \\{{ncog|la|diēs}}, {{ncog|ru|день}}, {{ncog|lt|dienà}} are [[false cognate]]s; they all derive from {{ncog|ine-pro|*dyew-||to shine}}.
    ;
    const resolver = TestResolverContext{ .terms = &.{ "English", "Latin", "Russian", "Lithuanian", "Proto-Indo-European", "moon", "false cognate" } };

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{
        .link_resolver = .{
            .context = @ptrCast(&resolver),
            .resolve = resolveTestLink,
        },
    });
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "/entry/English") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "/entry/moon") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "English") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Latin") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Russian") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Lithuanian") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Proto-Indo-European") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "to shine") != null);
}

test "renderEnglishSectionAlloc strips gallery filenames and keeps captions" {
    const source =
        \\==English==
        \\
        \\===Gallery===
        \\<gallery mode=packed>
        \\Image:Finger ring.jpg|A '''ring''' on a finger.
        \\Image:Tree rings.jpg|The '''rings''' of a tree.
        \\</gallery>
    ;

    const sections = try renderEnglishSectionAlloc(std.testing.allocator, source);
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Finger ring.jpg") == null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "A ring on a finger.") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "The rings of a tree.") != null);
}

test "renderEnglishSectionAlloc accepts place and etymology helpers in strict mode" {
    const source =
        \\==English==
        \\
        \\===Etymology===
        \\From {{der|en|fro|encloyer}}.
        \\
        \\===Proper noun===
        \\# {{place|en|country|c/Brazil|official=Republic of Brazil}}
    ;

    const sections = try renderEnglishSectionAlloc(std.testing.allocator, source);
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 2), sections.len);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Old French") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "encloyer") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[1].html, "A country in Brazil") != null);
}

test "renderEnglishSectionAlloc expands etymology borrowing and compound helpers with gloss detail" {
    const source =
        \\==English==
        \\
        \\===Etymology===
        \\From {{bor|en|frm|portemanteau||coat stand}}, from {{compound|frm|nocat=1|porter|alt1=porte|t1=carries|pos1=third-person singular present indicative of {{m|frm|porter|t=to carry}}|manteau|t2=coat|lit=[that which] carries coat}}.
    ;
    const resolver = TestResolverContext{ .terms = &.{ "Middle French", "portemanteau", "porter", "manteau" } };

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{
        .link_resolver = .{
            .context = @ptrCast(&resolver),
            .resolve = resolveTestLink,
        },
    });
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expect(sections[0].html.len != 0);
}

test "renderEnglishSectionAlloc preserves form-of template labels" {
    const source =
        \\==English==
        \\
        \\===Noun===
        \\{{head|en|noun form}}
        \\# {{plural of|en|Fresnel reflection}}
    ;

    const sections = try renderEnglishSectionAlloc(std.testing.allocator, source);
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "plural of Fresnel reflection") != null);
}

test "renderEnglishSectionAlloc treats context like label in strict mode" {
    const source =
        \\==English==
        \\
        \\===Verb===
        \\# {{context|transitive|lang=en}} To orbit.
    ;

    const sections = try renderEnglishSectionAlloc(std.testing.allocator, source);
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "transitive") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "To orbit.") != null);
}

test "renderEnglishSectionAlloc expands common inflection tags" {
    const source =
        \\==English==
        \\===Verb===
        \\# {{infl of|en|pie||s-verb-form}}
    ;

    const sections = try renderEnglishSectionAlloc(std.testing.allocator, source);
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "third-person singular simple present indicative of pie") != null);
}

test "renderEnglishSectionAlloc expands ed-form and ing-form inflection tags" {
    const source =
        \\==English==
        \\===Verb===
        \\# {{infl of|en|abandon||ed-form}}
        \\# {{infl of|en|abear||ing-form}}
    ;

    const sections = try renderEnglishSectionAlloc(std.testing.allocator, source);
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "simple past and past participle of abandon") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "present participle and gerund of abear") != null);
}

test "renderEnglishSectionAlloc preserves wiki link trails and alternative-form qualifiers" {
    const source =
        \\==English==
        \\
        \\===Noun===
        \\# A [[travel]]ling [[case]].
        \\#: {{alti|en|portemanteau|portmantua<q:obsolete>}}
    ;

    const sections = try renderEnglishSectionAlloc(std.testing.allocator, source);
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "travelling") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Alternative forms:") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "(obsolete) portmantua") != null);
}

const TestResolverContext = struct {
    terms: []const []const u8,
};

fn resolveTestLink(context: *const anyopaque, allocator: std.mem.Allocator, term: []const u8) !?[]const u8 {
    const resolver: *const TestResolverContext = @ptrCast(@alignCast(context));
    for (resolver.terms) |candidate| {
        if (std.ascii.eqlIgnoreCase(candidate, trimWikiWhitespace(term))) {
            return @as([]const u8, try allocator.dupe(u8, candidate));
        }
    }
    return null;
}

test "renderEnglishSectionAlloc links expanded shorthand form templates" {
    const source =
        \\==English==
        \\
        \\===Noun===
        \\{{head|en|noun form}}
        \\# {{plural of|en|Fresnel reflection}}
    ;
    const resolver = TestResolverContext{ .terms = &.{ "plural", "Fresnel reflection" } };

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{
        .link_resolver = .{
            .context = @ptrCast(&resolver),
            .resolve = resolveTestLink,
        },
    });
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "<a href=\"/entry/plural\">plural</a> of <a href=\"/entry/Fresnel%20reflection\">Fresnel reflection</a>") != null);
}

test "renderEnglishSectionAlloc expands init of and preserves nested wiki links" {
    const source =
        \\==English==
        \\
        \\===Noun===
        \\# {{init of|en|[[aeronautical|Aeronautical]] [[systems|Systems]] [[division|Division]]}}
    ;
    const resolver = TestResolverContext{ .terms = &.{ "initialism", "Aeronautical", "Systems", "Division" } };

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{
        .link_resolver = .{
            .context = @ptrCast(&resolver),
            .resolve = resolveTestLink,
        },
    });
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "<a href=\"/entry/initialism\">Initialism</a> of <a href=\"/entry/Aeronautical\">Aeronautical</a> <a href=\"/entry/Systems\">Systems</a> <a href=\"/entry/Division\">Division</a>") != null);
}

test "renderEnglishSectionAlloc preserves init of addl detail" {
    const source =
        \\==English==
        \\
        \\===Noun===
        \\# {{init of|en|[[guanosine]] [[diphosphate]]|addl=a [[nucleotide]]}}.
    ;
    const resolver = TestResolverContext{ .terms = &.{ "initialism", "guanosine", "diphosphate", "nucleotide" } };

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{
        .link_resolver = .{
            .context = @ptrCast(&resolver),
            .resolve = resolveTestLink,
        },
    });
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "<a href=\"/entry/initialism\">Initialism</a> of <a href=\"/entry/guanosine\">guanosine</a> <a href=\"/entry/diphosphate\">diphosphate</a>, a <a href=\"/entry/nucleotide\">nucleotide</a>.") != null);
}

test "renderEnglishSectionAlloc expands shorthand template families into full labels" {
    const source =
        \\==English==
        \\
        \\===Noun===
        \\# {{abbr of|en|aeronautical systems division}}
        \\# {{back-form|en|escalator}}
        \\# {{alt sp|en|colour}}
    ;
    const resolver = TestResolverContext{ .terms = &.{ "abbreviation", "aeronautical systems division", "back-formation", "escalator", "colour" } };

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{
        .link_resolver = .{
            .context = @ptrCast(&resolver),
            .resolve = resolveTestLink,
        },
    });
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "<a href=\"/entry/abbreviation\">Abbreviation</a> of <a href=\"/entry/aeronautical%20systems%20division\">aeronautical systems division</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "<a href=\"/entry/back-formation\">Back-formation</a> from <a href=\"/entry/escalator\">escalator</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Alternative spelling of <a href=\"/entry/colour\">colour</a>") != null);
}

test "renderEnglishSectionAlloc expands bf and omitted-base suffix etymologies" {
    const source =
        \\==English==
        \\
        \\===Etymology===
        \\From {{bf|en|linguist}} {{suf|en||-ism}}.
    ;
    const resolver = TestResolverContext{ .terms = &.{ "back-formation", "linguist", "-ism" } };

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{
        .link_resolver = .{
            .context = @ptrCast(&resolver),
            .resolve = resolveTestLink,
        },
    });
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "From <a href=\"/entry/back-formation\">Back-formation</a> from <a href=\"/entry/linguist\">linguist</a> + <a href=\"/entry/-ism\">-ism</a>.") != null);
}

test "renderEnglishSectionAlloc formats place and surname definitions like sentence glosses" {
    const source =
        \\==English==
        \\{{wp}}
        \\
        \\===Proper noun===
        \\{{en-proper noun}}
        \\
        \\# {{place|en|hamlet|par/Ipplepen|dist/Teignbridge|co/Devon|cc/England}} {{q|[[OS]] grid ref SX8566}}.
        \\# {{surname|en}}.
    ;

    const sections = try renderEnglishSectionAlloc(std.testing.allocator, source);
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "A hamlet in Ipplepen parish, Teignbridge district, Devon, England (OS grid ref SX8566).") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "A surname.") != null);
}

test "renderEnglishSectionAlloc preserves nominal template origins" {
    const source =
        \\==English==
        \\
        \\===Proper noun===
        \\# {{surname|en|habitational|from=Old Norse}}
    ;
    const resolver = TestResolverContext{ .terms = &.{"Old Norse"} };

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{
        .link_resolver = .{
            .context = @ptrCast(&resolver),
            .resolve = resolveTestLink,
        },
    });
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "A habitational surname from <a href=\"/entry/Old%20Norse\">Old Norse</a>") != null);
}

test "renderEnglishSectionAlloc preserves ellipsis-of targets for hyphenated terms" {
    const source =
        \\==English==
        \\====Noun====
        \\# {{lb|en|zoology}} {{ellipsis of|en|pie-dog|t=an [[Indian]] [[breed]], a [[stray dog]] in [[Indian]] [[context]]s}}.
    ;

    const sections = try renderEnglishSectionAlloc(std.testing.allocator, source);
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Ellipsis") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "pie-dog") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Indian") != null);
}

test "renderEnglishSectionAlloc preserves alternative-spelling targets that resemble language codes" {
    const source =
        \\==English==
        \\====Noun====
        \\# {{alternative spelling of|en|cro|t=marijuana}}
    ;

    const sections = try renderEnglishSectionAlloc(std.testing.allocator, source);
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "alternative spelling") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "cro") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "marijuana") != null);
}

test "renderEnglishSectionAlloc supports common etymology helper templates in strict mode" {
    const source =
        \\==English==
        \\
        \\===Etymology===
        \\{{deverbal|en|hand out}}.
        \\{{ellipsis|en|United Nations Organization}}.
        \\{{unknown|en|title=Origin unknown}}.
        \\{{surface analysis|en|ether|-ial|nocap=1}}.
        \\{{clip|en|technology}}.
        \\{{acronym|en|[[radio|'''ra'''dio]] [[detection|'''d'''etection]] [[and|'''a'''nd]] [[ranging|'''r'''anging]]|nocap=1}}.
    ;
    const resolver = TestResolverContext{ .terms = &.{ "hand out", "United Nations Organization", "ether", "-ial", "technology", "acronym" } };

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{
        .strict = true,
        .link_resolver = .{
            .context = @ptrCast(&resolver),
            .resolve = resolveTestLink,
        },
    });
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expect(sections[0].html.len != 0);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Deverbal") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Ellipsis") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Origin unknown.") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "surface analysis") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Clipping") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "acronym") != null);
}

test "renderEnglishSectionAlloc supports name translit and obsolete spelling templates in strict mode" {
    const source =
        \\==English==
        \\
        \\===Proper noun===
        \\# {{name translit|en|el|Αγγελόπουλος|type=surname}}.
        \\# {{obs sp|en|ail}}.
    ;

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{
        .strict = true,
    });
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "A transliteration of the Greek surname Αγγελόπουλος.") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Obsolete spelling of ail.") != null);
}

test "renderEnglishSectionAlloc expands Latn-def letter templates semantically" {
    const source =
        \\==English==
        \\====Letter====
        \\# {{Latn-def|en|letter|1|a}}
    ;

    const sections = try renderEnglishSectionAlloc(std.testing.allocator, source);
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "The first") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Latin script") != null);
}

test "renderEnglishSectionAlloc expands Latn-def ordinal templates semantically" {
    const source =
        \\==English==
        \\====Number====
        \\# {{Latn-def|en|ordinal|1|a}}
    ;

    const sections = try renderEnglishSectionAlloc(std.testing.allocator, source);
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "The first") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "numeral symbol") != null);
}

test "renderEnglishSectionAlloc chooses nominal articles from visible linked text" {
    const source =
        \\==English==
        \\
        \\===Proper noun===
        \\# {{given name|en|female|from=month names < English}}
    ;
    const resolver = TestResolverContext{ .terms = &.{ "female", "English" } };

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{
        .link_resolver = .{
            .context = @ptrCast(&resolver),
            .resolve = resolveTestLink,
        },
    });
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "A <a href=\"/entry/female\">female</a> given name") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "An <a href=\"/entry/female\">female</a> given name") == null);
}

test "renderEnglishSectionAlloc expands nominal month-name origins semantically" {
    const source =
        \\==English==
        \\
        \\===Proper noun===
        \\# {{given name|en|female|from=month names < English}}
    ;
    const resolver = TestResolverContext{ .terms = &.{ "female", "English" } };

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{
        .link_resolver = .{
            .context = @ptrCast(&resolver),
            .resolve = resolveTestLink,
        },
    });
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "A <a href=\"/entry/female\">female</a> given name transferred from the month name [in turn from <a href=\"/entry/English\">English</a>]") != null);
}

test "renderEnglishSectionAlloc preserves nominal addl text and expands &lit semantically" {
    const source =
        \\==English==
        \\
        \\===Proper noun===
        \\# {{given name|en|male|addl=or more often nickname, for a boy who is junior to someone else}}
        \\# {{&lit|en|false|friend}}
    ;
    const resolver = TestResolverContext{ .terms = &.{ "male", "false", "friend" } };

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{
        .link_resolver = .{
            .context = @ptrCast(&resolver),
            .resolve = resolveTestLink,
        },
    });
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "A <a href=\"/entry/male\">male</a> given name, or more often nickname, for a boy who is junior to someone else") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Used other than figuratively or idiomatically: see <a href=\"/entry/false\">false</a>, <a href=\"/entry/friend\">friend</a>") != null);
}

test "renderEnglishSectionAlloc links place holonyms from place template fragments" {
    const source =
        \\==English==
        \\
        \\===Proper noun===
        \\# {{place|en|town|metbor/Knowsley|co/Merseyside|cc/England}} {{q|[[OS]] grid ref SJ4491}}.
    ;
    const resolver = TestResolverContext{ .terms = &.{ "town", "Knowsley", "Merseyside", "England", "OS" } };

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{
        .link_resolver = .{
            .context = @ptrCast(&resolver),
            .resolve = resolveTestLink,
        },
    });
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "A <a href=\"/entry/town\">town</a> in the Metropolitan Borough of <a href=\"/entry/Knowsley\">Knowsley</a>, <a href=\"/entry/Merseyside\">Merseyside</a>, <a href=\"/entry/England\">England</a> (<a href=\"/entry/OS\">OS</a> grid ref SJ4491).") != null);
}

test "renderEnglishSectionAlloc respects suffixed province holonyms and capital-city place pairs" {
    const source =
        \\==English==
        \\
        \\===Proper noun===
        \\# {{place|en|city/capital city|province:suf/Ratanakiri|c/Cambodia}}.
        \\# {{place|en|district|province:suf/Ratanakiri|c/Cambodia}}.
    ;
    const resolver = TestResolverContext{ .terms = &.{ "city", "capital city", "district", "Ratanakiri", "Cambodia" } };

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{
        .link_resolver = .{
            .context = @ptrCast(&resolver),
            .resolve = resolveTestLink,
        },
    });
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "A <a href=\"/entry/city\">city</a>, the <a href=\"/entry/capital%20city\">capital city</a> of <a href=\"/entry/Ratanakiri\">Ratanakiri</a> province, <a href=\"/entry/Cambodia\">Cambodia</a>.") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "A <a href=\"/entry/district\">district</a> of <a href=\"/entry/Ratanakiri\">Ratanakiri</a> province, <a href=\"/entry/Cambodia\">Cambodia</a>.") != null);
}

test "renderEnglishSectionAlloc renders county-seat place pairs like wiktionary prose" {
    const source =
        \\==English==
        \\
        \\===Proper noun===
        \\# {{place|en|city/county seat|co/Clay County|s/Indiana|c/US}}.
    ;
    const resolver = TestResolverContext{ .terms = &.{ "city", "county seat", "Clay County", "Indiana", "United States" } };

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{
        .link_resolver = .{
            .context = @ptrCast(&resolver),
            .resolve = resolveTestLink,
        },
    });
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "A <a href=\"/entry/city\">city</a>, the <a href=\"/entry/county%20seat\">county seat</a> of <a href=\"/entry/Clay%20County\">Clay County</a>, <a href=\"/entry/Indiana\">Indiana</a>, <a href=\"/entry/United%20States\">United States</a>.") != null);
}

test "renderEnglishSectionAlloc expands combined place type shorthands" {
    const source =
        \\==English==
        \\
        \\===Proper noun===
        \\# {{place|en|village/and/cpar|in|co/North Yorkshire|cc/England|previously in|dist/Hambleton}}
    ;
    const resolver = TestResolverContext{ .terms = &.{ "village", "civil parish", "North Yorkshire", "England", "Hambleton" } };

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{
        .link_resolver = .{
            .context = @ptrCast(&resolver),
            .resolve = resolveTestLink,
        },
    });
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expect(std.mem.indexOf(
        u8,
        sections[0].html,
        "A <a href=\"/entry/village\">village</a> and <a href=\"/entry/civil%20parish\">civil parish</a> in <a href=\"/entry/North%20Yorkshire\">North Yorkshire</a>, <a href=\"/entry/England\">England</a>, previously in <a href=\"/entry/Hambleton\">Hambleton</a> district",
    ) != null);
}

test "renderEnglishSectionAlloc does not prepend an indefinite article to determiner-led place text" {
    const source =
        \\==English==
        \\
        \\===Proper noun===
        \\# {{place|en|The largest and most populous <<constituent country>> of the <<c/United Kingdom>>}}
    ;
    const resolver = TestResolverContext{ .terms = &.{ "constituent country", "United Kingdom" } };

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{
        .link_resolver = .{
            .context = @ptrCast(&resolver),
            .resolve = resolveTestLink,
        },
    });
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "A The largest") == null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "The largest and most populous <a href=\"/entry/constituent%20country\">constituent country</a> of the <a href=\"/entry/United%20Kingdom\">United Kingdom</a>") != null);
}

test "renderEnglishSectionAlloc preserves possessive apostrophes and external wiki links in lead captions" {
    const source =
        \\==English==
        \\[[File:Britannica Macropaedia.jpg|thumb|right|250px|Volumes 21–24 of ''Britannica'''s ''[[w:Macropædia|Macropædia]]'' (covering topics from ''India'' to ''Norway'') in the [[w:Deutsches Museum|Deutsches Museum]]'s library.]]
    ;

    const sections = try renderEnglishSectionAlloc(std.testing.allocator, source);
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Britannica's") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "https://en.wikipedia.org/wiki/Macrop%C3%A6dia") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "https://en.wikipedia.org/wiki/Deutsches_Museum") != null);
}

test "renderEnglishSectionAlloc strips bold apostrophe artifacts from acronym etymologies" {
    const source =
        \\==English==
        \\
        \\===Etymology===
        \\From '''H'''alo'''A'''cetic '''A'''cids.
    ;

    const sections = try renderEnglishSectionAlloc(std.testing.allocator, source);
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "HaloAcetic Acids.") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "H'alo") == null);
}

test "renderEnglishSectionAlloc expands standalone initialism etymologies" {
    const resolver = TestResolverContext{ .terms = &.{ "initialism", "Resistant", "oil", "particles", "ninety-five", "filtration", "efficiency" } };
    const source =
        \\==English==
        \\
        \\===Etymology===
        \\From {{initialism|en|[[resistant|'''R'''esistant]] [[to]] [[oil]] [[particles]] [[with]] [[ninety-five|'''95''']][[%]] [[filtration]] [[efficiency]]}} in {{w|lang=en|NIOSH air filtration rating}}s.
    ;

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{
        .link_resolver = .{
            .context = @ptrCast(&resolver),
            .resolve = resolveTestLink,
        },
    });
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "<a href=\"/entry/initialism\">Initialism</a> of <a href=\"/entry/Resistant\">Resistant</a> to <a href=\"/entry/oil\">oil</a> <a href=\"/entry/particles\">particles</a> with <a href=\"/entry/ninety-five\">95</a>% <a href=\"/entry/filtration\">filtration</a> <a href=\"/entry/efficiency\">efficiency</a>") != null);
}

test "renderEnglishSectionAlloc renders pronunciation templates with qualifiers and links" {
    const source =
        \\==English==
        \\===Pronunciation===
        \\* {{IPA|en|/pɔːtˈmæn.təʊ/|a=RP}}
        \\* {{enPR|pôrtmă'ntō|pô'rtmăntōʹ|a=US}}, {{IPA|en|/pɔːɹtˈmæntoʊ/|/ˌpɔːɹtmænˈtoʊ/}}
        \\* {{audio|en|en-us-portmanteau-1.ogg|a=US}}
        \\* {{rhymes|en|æntəʊ|əʊ|s=3}}
    ;

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{});
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Received Pronunciation") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "International_Phonetic_Alphabet") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "en-us-portmanteau-1.ogg") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Rhymes:") != null);
}

test "renderEnglishSectionAlloc keeps homophones in pronunciation sections" {
    const source =
        \\==English==
        \\===Pronunciation===
        \\* {{enPR|frē}}, {{IPA|en|/fɹiː/|[fɹɪi̯]}}
        \\* {{homophones|en|three|aa=th-fronting}}
    ;

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{});
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Homophone") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "three") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "th-fronting") != null);
}

test "renderEnglishSectionAlloc treats hmp like homophones" {
    const source =
        \\==English==
        \\===Pronunciation===
        \\* {{hmp|en|Cat|Kat|khat|qat}}
    ;
    const resolver = TestResolverContext{ .terms = &.{ "cat", "kat", "khat", "qat" } };

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{
        .link_resolver = .{
            .context = @ptrCast(&resolver),
            .resolve = resolveTestLink,
        },
    });
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Homophones:") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Cat") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Kat") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "khat") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "qat") != null);
}

test "renderEnglishSectionAlloc renders affix-style etymology templates structurally" {
    const source =
        \\==English==
        \\===Etymology===
        \\From {{confix|en|lexico|pos1=prefix meaning 'speech; words'|graphy|pos2=suffix meaning 'something written about a specified subject'}}. {{surf|en|diction|-ary}}. {{doublet|en|funt|pfund|pood|punt<id:Irish pound>}}.
    ;

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{});
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "lexico-") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "-graphy") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "punt&lt;id:Irish pound&gt;") == null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "punt") != null);
}

test "renderEnglishSectionAlloc renders senseno targets instead of raw ids" {
    const source =
        \\==English==
        \\===Noun===
        \\# {{senseid|en|Q23622}} A dictionary sense.
        \\
        \\===Noun===
        \\# {{lb|en|computing}} An array ({{senseno|en|Q23622}}).
    ;

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{});
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Q23622") == null);
    try std.testing.expect(std.mem.indexOf(u8, sections[1].html, "noun sense 1") != null);
}

test "renderEnglishSectionAlloc preserves synonym semicolon grouping and strips comment residue" {
    const source =
        \\==English==
        \\===Noun===
        \\# Test.
        \\#: {{syn|en|blend<!-- synonym 1 -->|frankenword<!-- synonym 2 -->|;|free as in beer}}
    ;

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{});
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "<!--") == null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "blend, frankenword; free as in beer") != null);
}

test "renderEnglishSectionAlloc keeps extra alter terms before qualifiers" {
    const source =
        \\==English==
        \\===Alternative forms===
        \\* {{alter|en|heed|hed|obsolete}}
        \\* {{alter|en|trade-wind|tradewind}}
    ;

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{});
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "heed, hed (obsolete)") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "trade-wind, tradewind") != null);
}

test "renderEnglishSectionAlloc skips category-only C templates in body sections" {
    const source =
        \\==English==
        \\====Derived terms====
        \\{{col|en|encyclopaedial|encyclopaedian|encyclopaedist}}
        \\
        \\{{C|en|Books}}
    ;

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{});
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "encyclopaedial") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Books") == null);
}

test "renderEnglishSectionAlloc expands compound plus etymologies" {
    const source =
        \\==English==
        \\===Etymology===
        \\{{compound+|en|trade|t1=course, path (of running)|pos1=from 14th c.|wind}}
    ;

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{});
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Compound of") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "trade") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "wind") != null);
}

test "renderEnglishSectionAlloc keeps standalone clipping etymology templates targetless" {
    const source =
        \\==English==
        \\===Etymology===
        \\Bookmaker sense by {{clipping|en|nocap=1}}.
    ;

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{});
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "clipping") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "clipping of") == null);
}

test "renderEnglishSectionAlloc reads numeric named args and clip-of semantics in HTML" {
    const source =
        \\==English==
        \\===Prefix===
        \\{{en-prefix}}
        \\# {{lb|en|Chester}} {{non-gloss|1=Used as a prefix to verbs in the sense of remaining in the same condition.}}
        \\===Noun===
        \\{{en-noun}}
        \\# {{lb|en|informal}} {{clip of|en|abdominal muscle}} {{defdate|mid 20<sup>th</sup> century}}.
    ;

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{});
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Used as a prefix to verbs in the sense of remaining in the same condition.") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[1].html, "Clipping") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[1].html, "abdominal muscle") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[1].html, "20") != null);
}

test "renderEnglishSectionAlloc prefixes affix etymologies with term languages" {
    const source =
        \\==English==
        \\===Etymology===
        \\From {{af|en|lang1=la|alphabēticus|-al}}.
    ;

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{});
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Latin") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "alphabēticus") != null);
}

test "renderEnglishSectionAlloc keeps quote archive and quotee metadata" {
    const source =
        \\==English==
        \\===Noun===
        \\#* {{quote-web|en|title=Example title|date=July 5, 2018|site=SRU News|publisher=[[w:Slippery Rock University|Slippery Rock University]]|location=[[w:Slippery Rock, Pennsylvania|Slippery Rock]]|archiveurl=https://web.archive.org/example|archivedate=July 13, 2012|quotee=Jason Hilton ([[associate professor|Assoc. Prof.]] of Education)|text=Example text.}}
    ;

    const sections = try renderEnglishSectionAlloc(std.testing.allocator, source);
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "archived from the original on 13 July 2012") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "quoting Jason Hilton") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Slippery Rock University") != null);
}

test "renderEnglishSectionAlloc keeps quote secondary publication metadata" {
    const source =
        \\==English==
        \\===Noun===
        \\#* {{quote-book|en|year=1751|author=Jean-Baptiste le Rond d'Alembert|chapter=Discours Préliminaire|title=Encyclopédie ou Dictionnaire raisonné des sciences, des arts et des métiers|title2=The Encyclopedia of Diderot & d'Alembert Collaborative Translation Project|publisher2=Michigan Publishing, University of Michigan Library|location2=[[w:Ann Arbor, Michigan|Ann Arbor]]|format2=Web|date2=April 18, 2009|chapter2=Preliminary Discourse|text=Example text.}}
    ;

    const sections = try renderEnglishSectionAlloc(std.testing.allocator, source);
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "republished as") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Preliminary Discourse") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "The Encyclopedia of Diderot") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Ann Arbor") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "18 April 2009") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Discours Préliminaire") != null);
}

test "renderEnglishSectionAlloc preserves etymology literal glosses and bare language origins" {
    const source =
        \\==English==
        \\===Etymology===
        \\From {{inh|en|gmw-pro|*Tīwas dag||Tuesday|lit=Tiw's Day}} and {{der|en|gmq|-}}.
    ;

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{});
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Proto-West Germanic") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "literally") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Tiw's Day") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "North Germanic") != null);
}

test "renderEnglishSectionAlloc expands Ottoman Turkish and Classical Persian etymology languages" {
    const source =
        \\==English==
        \\===Etymology===
        \\Borrowed from {{bor|en|ota|آبدست}} (modern {{cog|tr|abdest}}), from {{der|en|fa-cls|آبْدَسْت|tr=ābdast}}.
    ;

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{});
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Ottoman Turkish") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Turkish") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Classical Persian") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "ābdast") != null);
}

test "renderEnglishSectionAlloc expands learned borrowing templates semantically" {
    const source =
        \\==English==
        \\===Etymology===
        \\{{learned borrowing|en|la|[[absque]] [[hoc]]|lit=without this}}.
    ;

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{});
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "learned borrowing from") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Latin") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "absque") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "without this") != null);
}

test "renderEnglishSectionAlloc expands season name spelling usage note" {
    const source =
        \\==English==
        \\===Usage notes===
        \\{{season name spelling}}
    ;

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{});
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "season names are not capitalized") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "days of the week") != null);
}

test "renderEnglishSectionAlloc supports cognate alias template in etymology" {
    const source =
        \\==English==
        \\===Etymology===
        \\Ultimately a cognate with {{cognate|ang|earfoþe}} and {{cognate|de|Arbeit}}.
    ;

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{});
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Old English") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "German") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "earfoþe") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Arbeit") != null);
}

test "renderEnglishSectionAlloc links foreign lexeme templates and preserves transliteration glosses" {
    const source =
        \\==English==
        \\===Etymology===
        \\From {{m|fa-cls|آب|tr=āb|t=water}} and {{m|fa-cls|دست|tr=dast|t=hand}}.
    ;

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{});
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "<a") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "āb") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "dast") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "water") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "hand") != null);
}

test "renderEnglishSectionAlloc renders U templates and football labels with wiktionary-style wording" {
    const source =
        \\==English==
        \\===Proper noun===
        \\# {{lb|en|UK|football}} {{U|nickname}} of {{w|Sheffield Wednesday F.C.|Sheffield Wednesday}}.
    ;

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{});
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "(UK, soccer)") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Nickname") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "(nickname)") == null);
}

test "renderEnglishSectionAlloc renders quote-song titles with nested wiki formatting" {
    const source =
        \\==English==
        \\===Noun===
        \\#* {{quote-song|en|year=2017|artist=w:Arch Enemy|title={{w|Will to Power (Arch Enemy album)|The '''Eagle''' Flies Alone}}|passage=The '''eagle''' flies alone}}
    ;

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{
        .strict = true,
    });
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Eagle") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "flies alone") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "'''") == null);
}

test "renderEnglishSectionAlloc tolerates malformed standalone media links" {
    const source =
        \\==English==
        \\[[File:Several mobile phones.JPG|230px|thumb|{{lang|en|mobile phones]]
        \\
        \\===Noun===
        \\# A [[portable]] telephone.
    ;

    const sections = try renderEnglishSectionAlloc(std.testing.allocator, source);
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "portable") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Several mobile phones") == null);
}

test "renderEnglishSectionAlloc ignores inline column scaffolding templates" {
    const source =
        \\==English==
        \\===Etymology===
        \\{{col-top|2|cog}}
        \\* {{cog|sco|apen||open}}
        \\{{col-bottom}} Compare also {{cog|la|supinus||on one's back, supine}}.
    ;

    const sections = try renderEnglishSectionAlloc(std.testing.allocator, source);
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Compare also") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "supinus") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "col-bottom") == null);
}

test "renderEnglishSectionAlloc preserves defdate and thesaurus synonym links" {
    const source =
        \\==English==
        \\===Noun===
        \\# A [[reference work]]. {{defdate|ca. 1480}}
        \\#: {{syn|en|Thesaurus:dictionary}}
    ;

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{});
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "[ca. 1480]") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Synonyms: see") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "https://en.wiktionary.org/wiki/Thesaurus:dictionary") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Thesaurus:dictionary") != null);
}

test "renderEnglishSectionAlloc renders see thesaurus references in strict mode" {
    const source =
        \\==English==
        \\====Synonyms====
        \\* {{sense|greeting}} {{see thesaurus|en|hello}}
    ;
    const resolver = TestResolverContext{ .terms = &.{"Thesaurus:hello"} };

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{
        .link_resolver = .{
            .context = @ptrCast(&resolver),
            .resolve = resolveTestLink,
        },
    });
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "greeting") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "see ") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "/entry/Thesaurus%3Ahello") != null);
}

test "renderEnglishSectionAlloc ignores citation request templates in strict mode" {
    const source =
        \\==English==
        \\===Phrase===
        \\# A placeholder definition.
        \\#* {{see more citations|en}}
    ;

    const sections = try renderEnglishSectionAlloc(std.testing.allocator, source);
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "placeholder definition") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "see more citations") == null);
}

test "generated non-metadata templates never render to empty html" {
    if (generated.line_templates.len != 0) {
        var idx = generated.line_templates.len;
        while (idx > 0) {
            idx -= 1;
            const template = generated.line_templates[idx];
            if (generated_templates.classifyTemplateDispatchId(template.code) == .metadata_only) continue;

            const sample = try lineTemplateSampleAlloc(std.testing.allocator, template.name);
            defer std.testing.allocator.free(sample);

            const sections = try renderEnglishSectionAlloc(std.testing.allocator, sample);
            defer {
                for (sections) |*section| section.deinit(std.testing.allocator);
                std.testing.allocator.free(sections);
            }

            try std.testing.expect(renderedSectionsHaveVisibleHtml(sections));
        }
    }

    if (generated.translation_templates.len != 0) {
        var idx = generated.translation_templates.len;
        while (idx > 0) {
            idx -= 1;
            const template = generated.translation_templates[idx];
            if (generated_templates.classifyTemplateDispatchId(template.code) == .metadata_only) continue;

            const sample = try translationTemplateSampleAlloc(std.testing.allocator, template.name);
            defer std.testing.allocator.free(sample);

            const sections = try renderEnglishSectionAlloc(std.testing.allocator, sample);
            defer {
                for (sections) |*section| section.deinit(std.testing.allocator);
                std.testing.allocator.free(sections);
            }

            try std.testing.expect(renderedSectionsHaveVisibleHtml(sections));
        }
    }
}

test "renderEnglishSectionAlloc routes unsupported helpers through shared template text rendering" {
    const source =
        \\==English==
        \\===Etymology===
        \\From {{1|en|[[Acme]]}}.
    ;

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{
        .strict = false,
    });
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "/entry/Acme") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, ">Acme<") != null);
}

test "renderEnglishSectionAlloc renders abbreviation place templates with article and expanded country names" {
    const source =
        \\==English==
        \\
        \\===Proper noun===
        \\# {{place|en|@abbrev of:Alabama|state|c/US}}.
    ;
    const resolver = TestResolverContext{ .terms = &.{ "Alabama", "state", "United States" } };

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{
        .link_resolver = .{
            .context = @ptrCast(&resolver),
            .resolve = resolveTestLink,
        },
    });
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expect(std.mem.indexOf(
        u8,
        sections[0].html,
        "Abbreviation of <a href=\"/entry/Alabama\">Alabama</a>: a <a href=\"/entry/state\">state</a> of <a href=\"/entry/United%20States\">United States</a>.",
    ) != null);
}

test "renderEnglishSectionAlloc expands unadapted borrowing and plural present inflection tags" {
    const source =
        \\==English==
        \\
        \\===Etymology===
        \\{{ubor|en|la|ōs|t=the mouth}}.
        \\
        \\===Verb===
        \\# {{inflection of|en|be||1|p|simple|pres}}
    ;

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{});
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Unadapted borrowing from") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Latin") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "the mouth") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[1].html, "first-person plural simple present") != null);
}

test "renderEnglishSectionAlloc renders usage and only-used-in templates semantically" {
    const source =
        \\==English==
        \\
        \\===Usage notes===
        \\* {{U:en:be dead}}
        \\
        \\===Adjective===
        \\# {{only used in|en|man enough}}
    ;
    const resolver = TestResolverContext{ .terms = &.{ "be dead", "man enough" } };

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{
        .link_resolver = .{
            .context = @ptrCast(&resolver),
            .resolve = resolveTestLink,
        },
    });
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "/entry/be%20dead") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[1].html, "Only used in <a href=\"/entry/man%20enough\">man enough</a>.") != null);
}

test "renderEnglishSectionAlloc strict mode ignores raw text inside code tags" {
    const source =
        \\==English==
        \\
        \\===Noun===
        \\# <code><<nowiki/></code>
    ;

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{
        .strict = true,
    });
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "&lt;&lt;nowiki/&gt;") != null);
}

test "renderEnglishSectionAlloc keeps literal less-than text" {
    const source =
        \\==English==
        \\
        \\===Etymology===
        \\Borrowed from month names < English usage.
    ;

    const sections = try renderEnglishSectionAlloc(std.testing.allocator, source);
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "month names &lt; English usage.") != null);
}

test "renderEnglishSectionAlloc skips float tables and keeps later content" {
    const source =
        \\==English==
        \\
        \\===Noun===
        \\{| class="wikitable floatright"
        \\|-
        \\| ignored
        \\|}
        \\# A [[test]] entry.
    ;

    const sections = try renderEnglishSectionAlloc(std.testing.allocator, source);
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "A test entry.") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "wikitable") == null);
}

test "renderEnglishSectionAlloc tolerates stray closing wiki markup" {
    const source =
        \\==English==
        \\
        \\===Noun===
        \\# kept sense}}
    ;

    const sections = try renderEnglishSectionAlloc(std.testing.allocator, source);
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "kept sense") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "}}") == null);
}

test "renderEnglishSectionAlloc normalizes template names and renders dated-form and q-lite helpers" {
    const source =
        \\==English==
        \\
        \\===Noun===
        \\# {{dated_form|en|bra||item of underwear}}. {{defdate|from 1900s}}
        \\{{Webster_1913}}
        \\
        \\===See also===
        \\* {{l|en|6}} {{q-lite|Arabic numeral}}
    ;

    const sections = try renderEnglishSectionAlloc(std.testing.allocator, source);
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Dated form of") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "bra") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "from 1900s") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Webster") == null);
    try std.testing.expect(std.mem.indexOf(u8, sections[1].html, "Arabic numeral") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[1].html, "{{") == null);
}

test "renderEnglishSectionAlloc keeps nested wikilink labels inside external links" {
    const source =
        \\==English==
        \\
        \\===Noun===
        \\#* {{quote-book|en|title=[https://example.test [[Wikipedia:The Art of Cookery made Plain and Easy|The Art of Cookery made Plain and Easy]]]|passage=test}}
    ;

    const sections = try renderEnglishSectionAlloc(std.testing.allocator, source);
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "The Art of Cookery made Plain and Easy") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "https://example.test") == null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "[[") == null);
}

test "renderEnglishSectionAlloc expands usage and county-seat place templates" {
    const source =
        \\==English==
        \\
        \\===Usage notes===
        \\* {{sense|region}} {{U:en:I-P}}
        \\
        \\===Proper noun===
        \\# {{place|en|city/county seat|co/Clay County|s/Indiana|c/USA}}.
    ;

    const sections = try renderEnglishSectionAlloc(std.testing.allocator, source);
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "The use of Israel to refer to the region") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[1].html, "A city, the county seat of") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[1].html, "United States") != null);
}

test "renderEnglishSectionAlloc keeps Isreal semantic templates visible" {
    const source =
        \\==English==
        \\
        \\===Proper noun===
        \\# {{surname|en}}.
        \\# {{missp|en|Israel}}.
    ;
    const resolver = TestResolverContext{ .terms = &.{"Israel", "surname", "misspelling"} };

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{
        .link_resolver = .{
            .context = @ptrCast(&resolver),
            .resolve = resolveTestLink,
        },
    });
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "A surname.") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Misspelling") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Israel") != null);
}

test "renderEnglishSectionAlloc keeps full Isreal entry from collapsing to zero sections" {
    const source =
        \\==English==
        \\
        \\===Proper noun===
        \\{{en-proper noun|s}}
        \\
        \\# {{surname|en}}.
        \\# {{missp|en|Israel}}.
        \\#* {{quote-journal
        \\|en
        \\|date=September 14, 1852
        \\|journal={{w|Deseret News}}---Extra
        \\|url=https://archive.org/details/prohibitionfalla00engl/
        \\|location=Great [[Salt Lake City]], U. T.
        \\|issn=0745-4724
        \\|page=9
        \\|pageurl=https://archive.org/details/specialconferenc00chur/page/n8/
        \\|column=2
        \\|text=May the Lord God of '''Isreal'''{{sic|Israel}} bless you, in the name of Jesus Christ, AMEN.}}
        \\#* {{quote-book
        \\|en
        \\|year=1891
        \\|author=Francis M. English
        \\|title=Prohibition: A Fallacy, a Fanaticism, and an Absurdity, Contrary to the Constitution of the United States, the Laws of Creation, Civilization, Common Sense and Rational Progress, because Contrary to the Teachings of the Bible
        \\|url=https://archive.org/details/prohibitionfalla00engl/
        \\|location=[[Jerseyville]], Ill.
        \\|publisher=Commercial Book and Job Printing Office
        \\|OCLC=1051748393
        \\|page=38
        \\|pageurl=https://archive.org/details/prohibitionfalla00engl/page/38/
        \\|text=1st SAMUEL.<br>Is the next book to Ruth. 1st ch, 24 v is a wonderful use of ''wine'', especially as it was an integral in the dedication of her son, Samuel, to the service of the God of '''Isreal'''{{sic|Israel}}. It is worth more than the time for the reader at convenience to turn to this chapter and read it all.}}
        \\#* {{quote-journal
        \\|en
        \\|year=1965
        \\|month=December
        \\|author=Leo Ebreo
        \\|title=A Homosexual Ghetto?
        \\|journal={{w|The Ladder (magazine)|The Ladder}}: A Lesbian Review
        \\|url=https://archive.org/details/sim_ladder_1965-12_10_3/
        \\|volume=10
        \\|issue=3
        \\|location=[[San Francisco]]
        \\|publisher=w:Daughters of Bilitis
        \\|issn=0023-7108
        \\|oclc=2263409
        \\|page=4
        \\|pageurl=https://archive.org/details/sim_ladder_1965-12_10_3/page/4/
        \\|text=When I was younger - about sixteen - I was an active Zionist. I believed that the best thing for American Jews, in fact all Jews, to do would be to go to '''Isreal'''{{sic|Israel}} and live in a kibbutz (collective). I belonged to a Zionist "movement" and tried to get the Jews I knew to join. I expected of course that few would want to emigrate, but I thought that most would be interested in helping '''Isreal'''{{sic|Israel}} and the Zionist movement.}}
        \\#* {{see more citations|en}}
    ;
    const resolver = TestResolverContext{ .terms = &.{
        "Israel",
        "surname",
        "misspelling",
        "Deseret News",
        "Salt Lake City",
        "Jerseyville",
        "The Ladder",
        "San Francisco",
    } };

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{
        .link_resolver = .{
            .context = @ptrCast(&resolver),
            .resolve = resolveTestLink,
        },
    });
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "A surname.") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Misspelling") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Deseret News") != null);
}

test "renderEnglishSectionAlloc skips malformed hidden media links in strict mode" {
    const source =
        \\==English==
        \\[[File:Several mobile phones.JPG|230px|thumb|{{lang|en|mobile phones]]
        \\
        \\===Noun===
        \\# A [[portable]] telephone.
    ;

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{
        .strict = true,
    });
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "A portable telephone.") != null);
}

test "renderEnglishSectionAlloc strict mode accepts open etymology column footer" {
    const source =
        \\==English==
        \\===Etymology===
        \\{{col-top|2|cog}}
        \\* {{cog|sco|apen||open}}
        \\{{col-bottom}} Compare also {{cog|la|supinus||on one's back, supine}}, {{cog|sq|hap||to open}}. Related to {{m|en|up}}.
    ;

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{
        .strict = true,
    });
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Compare also") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "supinus") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Related to") != null);
}

test "renderEnglishSectionAlloc strict mode accepts aphetic form etymology" {
    const source =
        \\==English==
        \\===Etymology===
        \\{{aphetic form|en|escarp}}. {{doublet|en|sharp}}.
    ;

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{
        .strict = true,
    });
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "escarp") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "sharp") != null);
}

test "renderEnglishSectionAlloc strict mode accepts near-synonyms in sense blocks" {
    const source =
        \\==English==
        \\===Proper noun===
        \\# {{place|en|country|r/South Caucasus|in|cont/Asia,Europe|official=Republic of Azerbaijan|capital=Baku}}.
        \\#: {{near-synonyms|en|q=historical|Arran|Shirvan}}
    ;

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{
        .strict = true,
    });
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Arran") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Shirvan") != null);
}

test "renderEnglishSectionAlloc expands onomatopoeic etymology labels" {
    const source =
        \\==English==
        \\===Etymology 1===
        \\{{onom|en}}.
    ;

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{});
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Onomatopoeic") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "en.") == null);
}

test "renderEnglishSectionAlloc expands coordinate list templates inside labeled bullets" {
    const source =
        \\==English==
        \\====Coordinate terms====
        \\* {{sense|country in South America}} {{list:countries in South America/en}}
    ;

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{});
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "country in South America") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Argentina") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Brazil") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Venezuela") != null);
}

test "renderEnglishSectionAlloc expands province list templates in meronym sections" {
    const source =
        \\==English==
        \\====Meronyms====
        \\{{list:provinces of Equatorial Guinea/en}}
    ;

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{});
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Annobón") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Bioko Norte") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Wele-Nzas") != null);
}

test "renderEnglishSectionAlloc renders alternative case forms semantically" {
    const source =
        \\==English==
        \\====Noun====
        \\# {{alt case form|en|china|id=chinaware}}: [[porcelain]] [[tableware]].
    ;

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{
        .strict = true,
    });
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Alternative case form of") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "china") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "porcelain tableware") != null);
}

test "renderEnglishSectionAlloc renders partial calques semantically" {
    const source =
        \\==English==
        \\===Etymology===
        \\{{partial calque|en|fr|cap vert}}.
    ;

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{
        .strict = true,
    });
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "Partial calque") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "cap vert") != null);
}

test "renderEnglishSectionAlloc repairs dangling wikilinks before the next bullet in strict mode" {
    const source =
        \\==English==
        \\====Derived terms====
        \\* [[ groundsel bush
        \\* [[groundsel tree]]
    ;

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{
        .strict = true,
    });
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "groundsel bush") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "groundsel tree") != null);
}

test "renderEnglishSectionAlloc keeps permissive rendering from failing on residual wiki markup" {
    const source =
        \\==English==
        \\====Derived terms====
        \\* [[ groundsel bush
    ;

    const sections = try renderEnglishSectionWithOptionsAlloc(std.testing.allocator, source, .{
        .strict = false,
    });
    defer {
        for (sections) |*section| section.deinit(std.testing.allocator);
        std.testing.allocator.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expect(std.mem.indexOf(u8, sections[0].html, "groundsel bush") != null);
}
