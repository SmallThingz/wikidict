//! Coordinated build-time Lua/template expansion and data-only blob bundling.
const std = @import("std");
const paths = @import("pipeline_paths");
const expansion_deadline = @import("expansion_deadline.zig");
const max_parallel_workers: usize = 4;
const clang_common_flags = [_][]const u8{ "-march=native", "-fno-lto", "-Wno-override-module" };
const clang_program_mode = "-O1";

const Options = struct {
    dump: []const u8,
    root: []const u8,
    namespace_registry_snapshot: ?[]const u8 = null,
    site_info_snapshot: ?[]const u8 = null,
    page_language_snapshot: ?[]const u8 = null,
    figure_siteinfo_snapshot: ?[]const u8 = null,
    figure_sizing_snapshot: ?[]const u8 = null,
    figure_sizing_raw_snapshot: ?[]const u8 = null,
    figure_sizing_site_snapshot: ?[]const u8 = null,
    figure_page_observations_snapshot: ?[]const u8 = null,
    site_statistics_format_snapshot: ?[]const u8 = null,
    commons_data_snapshot: ?[]const u8 = null,
    category_stats_snapshot: ?[]const u8 = null,
    category_statistics_format_snapshot: ?[]const u8 = null,
    interface_messages_snapshot: ?[]const u8 = null,
    category_tree_snapshot: ?[]const u8 = null,
    interwiki_map_snapshot: ?[]const u8 = null,
    wikibase_sitelinks_snapshot: ?[]const u8 = null,
    wikibase_entity_text_snapshot: ?[]const u8 = null,
    wikibase_entities_snapshot: ?[]const u8 = null,
    wikibase_entity_terms_snapshot: ?[]const u8 = null,
    wikibase_page_links_snapshot: ?[]const u8 = null,
    page_redirects_snapshot: ?[]const u8 = null,
    language_registry_snapshot: ?[]const u8 = null,
    language_fallbacks_snapshot: ?[]const u8 = null,
    language_names_snapshot: ?[]const u8 = null,
    date_numbering_snapshot: ?[]const u8 = null,
    behavior_switches_snapshot: ?[]const u8 = null,
    image_options_snapshot: ?[]const u8 = null,
    magic_words_snapshot: ?[]const u8 = null,
    parser_function_facts_snapshot: ?[]const u8 = null,
    file_metadata_snapshot: ?[]const u8 = null,
    transclusion_redirects_snapshot: ?[]const u8 = null,
    stylesheet_imports_snapshot: ?[]const u8 = null,
    llvm_workers: ?usize = null,
    page_workers: usize = 1,
    expansion_timeout_ms: ?u32 = null,
    now_unix: ?i64 = null,
    parse_workers: usize = 4,
    expander_only: bool = false,
    seal_prepared_source: bool = false,
    sealed_frontend_reference: ?[]const u8 = null,
    reviewed_nonlexical: ?[]const u8 = null,
    extraction_cache_root: ?[]const u8 = null,
    verified_dump_sha256: ?[]const u8 = null,
    verified_index_sha256: ?[]const u8 = null,
    verified_source_pages: ?u64 = null,
    bzip2_source_directory: ?[]const u8 = null,
};

fn parseOptions(args: []const []const u8) !Options {
    if (args.len < 2) return error.Usage;
    var options: Options = .{ .dump = args[0], .root = args[1], .parse_workers = @min(4, std.Thread.getCpuCount() catch 1) };
    var index: usize = 2;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--bzip2-source-directory")) {
            index += 1;
            if (index >= args.len or options.bzip2_source_directory != null or !std.fs.path.isAbsolute(args[index]) or std.mem.indexOfScalar(u8, args[index], 0) != null) return error.Usage;
            options.bzip2_source_directory = args[index];
        } else if (std.mem.eql(u8, args[index], "--namespace-registry-snapshot")) {
            index += 1;
            if (index >= args.len or options.namespace_registry_snapshot != null) return error.Usage;
            options.namespace_registry_snapshot = args[index];
        } else if (std.mem.eql(u8, args[index], "--stylesheet-imports-snapshot")) {
            index += 1;
            if (index >= args.len or options.stylesheet_imports_snapshot != null) return error.Usage;
            options.stylesheet_imports_snapshot = args[index];
        } else if (std.mem.eql(u8, args[index], "--page-language-snapshot")) {
            index += 1;
            if (index >= args.len or options.page_language_snapshot != null or args[index].len == 0 or std.mem.startsWith(u8, args[index], "--")) return error.Usage;
            options.page_language_snapshot = args[index];
        } else if (std.mem.eql(u8, args[index], "--site-info-snapshot")) {
            index += 1;
            if (index >= args.len or options.site_info_snapshot != null) return error.Usage;
            options.site_info_snapshot = args[index];
        } else if (std.mem.eql(u8, args[index], "--site-statistics-format-snapshot")) {
            index += 1;
            if (index >= args.len or options.site_statistics_format_snapshot != null) return error.Usage;
            options.site_statistics_format_snapshot = args[index];
        } else if (std.mem.eql(u8, args[index], "--figure-siteinfo-snapshot")) {
            index += 1;
            if (index >= args.len or options.figure_siteinfo_snapshot != null or args[index].len == 0 or std.mem.startsWith(u8, args[index], "--")) return error.Usage;
            options.figure_siteinfo_snapshot = args[index];
        } else if (std.mem.eql(u8, args[index], "--figure-sizing-snapshot")) {
            index += 1;
            if (index >= args.len or options.figure_sizing_snapshot != null or args[index].len == 0 or std.mem.startsWith(u8, args[index], "--")) return error.Usage;
            options.figure_sizing_snapshot = args[index];
        } else if (std.mem.eql(u8, args[index], "--figure-sizing-raw-snapshot")) {
            index += 1;
            if (index >= args.len or options.figure_sizing_raw_snapshot != null or args[index].len == 0 or std.mem.startsWith(u8, args[index], "--")) return error.Usage;
            options.figure_sizing_raw_snapshot = args[index];
        } else if (std.mem.eql(u8, args[index], "--figure-page-observations-snapshot")) {
            index += 1;
            if (index >= args.len or options.figure_page_observations_snapshot != null or args[index].len == 0 or std.mem.startsWith(u8, args[index], "--")) return error.Usage;
            options.figure_page_observations_snapshot = args[index];
        } else if (std.mem.eql(u8, args[index], "--figure-sizing-site-snapshot")) {
            index += 1;
            if (index >= args.len or options.figure_sizing_site_snapshot != null or args[index].len == 0 or std.mem.startsWith(u8, args[index], "--")) return error.Usage;
            options.figure_sizing_site_snapshot = args[index];
        } else if (std.mem.eql(u8, args[index], "--commons-data-snapshot")) {
            index += 1;
            if (index >= args.len or options.commons_data_snapshot != null) return error.Usage;
            options.commons_data_snapshot = args[index];
        } else if (std.mem.eql(u8, args[index], "--category-stats-snapshot")) {
            index += 1;
            if (index >= args.len or options.category_stats_snapshot != null) return error.Usage;
            options.category_stats_snapshot = args[index];
        } else if (std.mem.eql(u8, args[index], "--category-statistics-format-snapshot")) {
            index += 1;
            if (index >= args.len or options.category_statistics_format_snapshot != null) return error.Usage;
            options.category_statistics_format_snapshot = args[index];
        } else if (std.mem.eql(u8, args[index], "--interface-messages-snapshot")) {
            index += 1;
            if (index >= args.len or options.interface_messages_snapshot != null) return error.Usage;
            options.interface_messages_snapshot = args[index];
        } else if (std.mem.eql(u8, args[index], "--category-tree-snapshot")) {
            index += 1;
            if (index >= args.len or options.category_tree_snapshot != null) return error.Usage;
            options.category_tree_snapshot = args[index];
        } else if (std.mem.eql(u8, args[index], "--interwiki-map-snapshot")) {
            index += 1;
            if (index >= args.len or options.interwiki_map_snapshot != null) return error.Usage;
            options.interwiki_map_snapshot = args[index];
        } else if (std.mem.eql(u8, args[index], "--wikibase-sitelinks-snapshot")) {
            index += 1;
            if (index >= args.len or options.wikibase_sitelinks_snapshot != null) return error.Usage;
            options.wikibase_sitelinks_snapshot = args[index];
        } else if (std.mem.eql(u8, args[index], "--wikibase-entity-text-snapshot")) {
            index += 1;
            if (index >= args.len or options.wikibase_entity_text_snapshot != null) return error.Usage;
            options.wikibase_entity_text_snapshot = args[index];
        } else if (std.mem.eql(u8, args[index], "--wikibase-entities-snapshot")) {
            index += 1;
            if (index >= args.len or options.wikibase_entities_snapshot != null) return error.Usage;
            options.wikibase_entities_snapshot = args[index];
        } else if (std.mem.eql(u8, args[index], "--page-redirects-snapshot")) {
            index += 1;
            if (index >= args.len or options.page_redirects_snapshot != null) return error.Usage;
            options.page_redirects_snapshot = args[index];
        } else if (std.mem.eql(u8, args[index], "--wikibase-page-links-snapshot")) {
            index += 1;
            if (index >= args.len or options.wikibase_page_links_snapshot != null) return error.Usage;
            options.wikibase_page_links_snapshot = args[index];
        } else if (std.mem.eql(u8, args[index], "--wikibase-entity-terms-snapshot")) {
            index += 1;
            if (index >= args.len or options.wikibase_entity_terms_snapshot != null) return error.Usage;
            options.wikibase_entity_terms_snapshot = args[index];
        } else if (std.mem.eql(u8, args[index], "--language-registry-snapshot")) {
            index += 1;
            if (index >= args.len or options.language_registry_snapshot != null) return error.Usage;
            options.language_registry_snapshot = args[index];
        } else if (std.mem.eql(u8, args[index], "--date-numbering-snapshot")) {
            index += 1;
            if (index >= args.len or options.date_numbering_snapshot != null) return error.Usage;
            options.date_numbering_snapshot = args[index];
        } else if (std.mem.eql(u8, args[index], "--language-names-snapshot")) {
            index += 1;
            if (index >= args.len or options.language_names_snapshot != null) return error.Usage;
            options.language_names_snapshot = args[index];
        } else if (std.mem.eql(u8, args[index], "--language-fallbacks-snapshot")) {
            index += 1;
            if (index >= args.len or options.language_fallbacks_snapshot != null) return error.Usage;
            options.language_fallbacks_snapshot = args[index];
        } else if (std.mem.eql(u8, args[index], "--image-options-snapshot")) {
            index += 1;
            if (index >= args.len or options.image_options_snapshot != null) return error.Usage;
            options.image_options_snapshot = args[index];
        } else if (std.mem.eql(u8, args[index], "--behavior-switches-snapshot")) {
            index += 1;
            if (index >= args.len or options.behavior_switches_snapshot != null) return error.Usage;
            options.behavior_switches_snapshot = args[index];
        } else if (std.mem.eql(u8, args[index], "--parser-function-facts-snapshot")) {
            index += 1;
            if (index >= args.len or options.parser_function_facts_snapshot != null or args[index].len == 0 or std.mem.startsWith(u8, args[index], "--")) return error.Usage;
            options.parser_function_facts_snapshot = args[index];
        } else if (std.mem.eql(u8, args[index], "--magic-words-snapshot")) {
            index += 1;
            if (index >= args.len or options.magic_words_snapshot != null) return error.Usage;
            options.magic_words_snapshot = args[index];
        } else if (std.mem.eql(u8, args[index], "--file-metadata-snapshot")) {
            index += 1;
            if (index >= args.len or options.file_metadata_snapshot != null) return error.Usage;
            options.file_metadata_snapshot = args[index];
        } else if (std.mem.eql(u8, args[index], "--transclusion-redirects-snapshot")) {
            index += 1;
            if (index >= args.len or options.transclusion_redirects_snapshot != null) return error.Usage;
            options.transclusion_redirects_snapshot = args[index];
        } else if (std.mem.eql(u8, args[index], "--llvm-workers")) {
            index += 1;
            if (index >= args.len or options.llvm_workers != null) return error.Usage;
            const workers = std.fmt.parseInt(usize, args[index], 10) catch return error.Usage;
            if (workers == 0 or workers > max_parallel_workers) return error.Usage;
            options.llvm_workers = workers;
        } else if (std.mem.eql(u8, args[index], "--parse-workers")) {
            index += 1;
            if (index >= args.len) return error.Usage;
            options.parse_workers = std.fmt.parseInt(usize, args[index], 10) catch return error.Usage;
            if (options.parse_workers == 0 or options.parse_workers > max_parallel_workers) return error.Usage;
        } else if (std.mem.eql(u8, args[index], "--sealed-frontend-reference")) {
            index += 1;
            if (index >= args.len or options.sealed_frontend_reference != null or args[index].len == 0 or
                std.mem.startsWith(u8, args[index], "--")) return error.Usage;
            options.sealed_frontend_reference = args[index];
        } else if (std.mem.eql(u8, args[index], "--seal-prepared-source")) {
            if (options.seal_prepared_source) return error.Usage;
            options.seal_prepared_source = true;
        } else if (std.mem.eql(u8, args[index], "--expander-only")) {
            if (options.expander_only) return error.Usage;
            options.expander_only = true;
        } else if (std.mem.eql(u8, args[index], "--reviewed-nonlexical")) {
            index += 1;
            if (index >= args.len or options.reviewed_nonlexical != null) return error.Usage;
            if (args[index].len == 0 or std.mem.startsWith(u8, args[index], "--")) return error.Usage;
            options.reviewed_nonlexical = args[index];
        } else if (std.mem.eql(u8, args[index], "--extraction-cache-root")) {
            index += 1;
            if (index >= args.len or options.extraction_cache_root != null) return error.Usage;
            options.extraction_cache_root = args[index];
        } else if (std.mem.eql(u8, args[index], "--verified-dump-sha256")) {
            index += 1;
            if (index >= args.len or options.verified_dump_sha256 != null) return error.Usage;
            options.verified_dump_sha256 = args[index];
        } else if (std.mem.eql(u8, args[index], "--verified-index-sha256")) {
            index += 1;
            if (index >= args.len or options.verified_index_sha256 != null) return error.Usage;
            options.verified_index_sha256 = args[index];
        } else if (std.mem.eql(u8, args[index], "--verified-source-pages")) {
            index += 1;
            if (index >= args.len or options.verified_source_pages != null or args[index].len == 0) return error.Usage;
            for (args[index]) |digit| if (!std.ascii.isDigit(digit)) return error.Usage;
            options.verified_source_pages = std.fmt.parseInt(u64, args[index], 10) catch return error.Usage;
        } else if (std.mem.eql(u8, args[index], "--expansion-timeout-ms")) {
            index += 1;
            if (index >= args.len or options.expansion_timeout_ms != null) return error.Usage;
            options.expansion_timeout_ms = try expansion_deadline.parse(args[index]);
        } else if (std.mem.eql(u8, args[index], "--now-unix")) {
            index += 1;
            if (index >= args.len or options.now_unix != null) return error.Usage;
            options.now_unix = std.fmt.parseInt(i64, args[index], 10) catch return error.Usage;
            if (options.now_unix.? <= 0) return error.Usage;
        } else if (std.mem.eql(u8, args[index], "--page-workers")) {
            index += 1;
            if (index >= args.len) return error.Usage;
            options.page_workers = std.fmt.parseInt(usize, args[index], 10) catch return error.Usage;
            if (options.page_workers == 0 or options.page_workers > max_parallel_workers) return error.Usage;
        } else return error.Usage;
    }
    if ((options.extraction_cache_root == null) != (options.verified_dump_sha256 == null) or
        (options.extraction_cache_root == null) != (options.verified_index_sha256 == null)) return error.Usage;
    if (options.verified_source_pages != null and (options.extraction_cache_root == null or options.bzip2_source_directory == null or options.sealed_frontend_reference != null)) return error.Usage;
    for ([_]?[]const u8{ options.verified_dump_sha256, options.verified_index_sha256 }) |maybe_digest| {
        if (maybe_digest) |digest| {
            if (digest.len != 64) return error.Usage;
            for (digest) |ch| {
                _ = std.fmt.charToDigit(ch, 16) catch return error.Usage;
            }
        }
    }
    if (options.bzip2_source_directory != null and
        (!std.fs.path.isAbsolute(options.dump) or std.mem.indexOfScalar(u8, options.dump, 0) != null or options.reviewed_nonlexical != null)) return error.Usage;
    // This execution manifest is consumed only by the final blob stage.
    // Refuse to accept approval input that an expander-only build cannot use.
    if (options.expander_only and options.reviewed_nonlexical != null) return error.Usage;
    if (options.seal_prepared_source and (!options.expander_only or options.extraction_cache_root == null)) return error.Usage;
    if (options.sealed_frontend_reference != null and !options.seal_prepared_source) return error.Usage;
    // The projection and its raw/site/default authority travel together.
    const figure_count = @as(u8, @intFromBool(options.figure_siteinfo_snapshot != null)) +
        @as(u8, @intFromBool(options.figure_sizing_snapshot != null)) +
        @as(u8, @intFromBool(options.figure_sizing_raw_snapshot != null)) +
        @as(u8, @intFromBool(options.figure_sizing_site_snapshot != null));
    if (figure_count != 0 and figure_count != 4) return error.Usage;
    if (options.figure_page_observations_snapshot != null and figure_count != 4) return error.Usage;
    return options;
}

fn blobStageArgv(
    buffer: *[13][]const u8,
    options: Options,
    reviewed_manifest: ?[]const u8,
    expander_root: []const u8,
    page_workers_text: []const u8,
    timeout_text: []const u8,
    now_text: []const u8,
) []const []const u8 {
    buffer.* = .{
        paths.blobs, options.dump, options.root, "--expander-root", expander_root,
        "--workers", page_workers_text, "--expansion-timeout-ms", timeout_text,
        "--now-unix", now_text, "", "",
    };
    if (reviewed_manifest) |manifest| {
        buffer[11] = "--reviewed-nonlexical";
        buffer[12] = manifest;
        return buffer[0..13];
    }
    if (options.bzip2_source_directory) |directory| {
        buffer[11] = "--bzip2-source-directory";
        buffer[12] = directory;
        return buffer[0..13];
    }
    return buffer[0..11];
}

fn defaultLlvmWorkersForCpuCount(logical_cpu_threads: usize) usize {
    const threads = @max(logical_cpu_threads, 1);
    return @min(max_parallel_workers, 1 + threads / 3);
}

fn defaultLlvmWorkers() usize {
    return defaultLlvmWorkersForCpuCount(std.Thread.getCpuCount() catch 1);
}

fn stage(io: std.Io, marker: []const u8, name: []const u8, argv: []const []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = marker, .data = name });
    std.debug.print("dictionary build: {s}\n", .{name});
    const started_ns = std.Io.Clock.awake.now(io).toNanoseconds();
    var child = try std.process.spawn(io, .{ .argv = argv, .stdin = .ignore });
    defer child.kill(io);
    const term = try child.wait(io);
    const elapsed_ms = @divTrunc(std.Io.Clock.awake.now(io).toNanoseconds() - started_ns, std.time.ns_per_ms);
    if (term != .exited or term.exited != 0) {
        std.debug.print("dictionary build failed at {s} elapsed_ms={d}; incomplete marker retained\n", .{ name, elapsed_ms });
        return error.PipelineStageFailed;
    }
    std.debug.print("dictionary build completed: {s} elapsed_ms={d}\n", .{ name, elapsed_ms });
}

const OriginalSourceDirectory = struct {
    format: []const u8,
    zstd_frame_bridge: ?struct {
        dump_bytes: u64,
        dump_sha256: []const u8,
        offset_index_bytes: u64,
        offset_index_sha256: []const u8,
    } = null,
};

fn originalTransportDescriptorBytes(a: std.mem.Allocator, options: Options) ![]u8 {
    const source_directory = options.bzip2_source_directory orelse return error.Usage;
    if (!std.fs.path.isAbsolute(options.dump) or !std.fs.path.isAbsolute(source_directory)) return error.Usage;
    return std.json.Stringify.valueAlloc(a, .{
        .format = "wikidict-source-transport-v1", .transport = "bzip2-blocks",
        .block_directory = options.dump, .source_directory = source_directory,
    }, .{});
}

fn installOriginalTransport(io: std.Io, a: std.mem.Allocator, options: Options, root: []const u8) !void {
    if (options.bzip2_source_directory == null) return;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, options.dump, a, .limited(64 * 1024 * 1024));
    defer a.free(bytes);
    const directory = try std.json.parseFromSlice(OriginalSourceDirectory, a, bytes, .{ .ignore_unknown_fields = true });
    defer directory.deinit();
    if (!std.mem.eql(u8, directory.value.format, "wikidict-bzip2-blocks-v1")) return error.InvalidBzip2Directory;
    if (options.extraction_cache_root != null) {
        // Cache coordinates name the independently reproduced logical stage,
        // never the physical archive or descriptor bytes.
        const bridge = directory.value.zstd_frame_bridge orelse return error.MissingBzip2Bridge;
        if (bridge.dump_bytes == 0 or bridge.offset_index_bytes == 0 or
            !std.mem.eql(u8, bridge.dump_sha256, options.verified_dump_sha256.?) or
            !std.mem.eql(u8, bridge.offset_index_sha256, options.verified_index_sha256.?)) return error.Bzip2BridgeIdentityMismatch;
    }
    const descriptor = try originalTransportDescriptorBytes(a, options);
    defer a.free(descriptor);
    const path = try std.fs.path.join(a, &.{ root, "source-transport.json" });
    defer a.free(path);
    // root is a newly created ordinary work directory. Install before probe;
    // normal v3 cache/receipt validation authenticates this exact regular file.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = descriptor });
}

fn extractionStageArgv(buffer: *[6][]const u8, executable: []const u8, dump: []const u8, root: []const u8, source_directory: ?[]const u8) []const []const u8 {
    buffer.* = .{ executable, dump, root, "--page-index", "", "" };
    if (source_directory) |directory| {
        buffer[4] = "--bzip2-source-directory";
        buffer[5] = directory;
        return buffer[0..6];
    }
    return buffer[0..4];
}

// One owner waits/reaps the extractor. The compiler may start after its inputs
// are flushed while extraction finishes the independent title index. Always
// join, including compiler errors, so no child outlives a failed pipeline.
const Extraction = struct {
    io: std.Io,
    child: std.process.Child,
    done: std.atomic.Value(bool) = .init(false),
    failure: ?anyerror = null,

    fn wait(self: *Extraction) void {
        defer self.done.store(true, .release);
        defer self.child.kill(self.io);
        const term = self.child.wait(self.io) catch |err| {
            self.failure = err;
            return;
        };
        if (term != .exited or term.exited != 0) self.failure = error.PipelineStageFailed;
    }
};

fn boundedParseWorkers(requested: usize, cpu_limit: usize, extractor_running: bool) usize {
    const reserved = @as(usize, @intFromBool(extractor_running));
    return @min(requested, @max(@as(usize, 1), cpu_limit -| reserved));
}

fn extractAndCompile(io: std.Io, a: std.mem.Allocator, marker: []const u8, dump: []const u8, root: []const u8, llvm_dir: []const u8, workers: usize, cpu_limit: usize, leaf_bc: []const u8, source_directory: ?[]const u8) !void {
    const ready = try std.fs.path.join(a, &.{ root, "compiler-inputs.ready" });
    const manifest = try std.fs.path.join(a, &.{ root, "manifest.jsonl" });
    // A failed prior build can leave a readiness marker in a reused output
    // directory. Remove it before the new extractor starts truncating and
    // rebuilding its inputs, otherwise LLVM can race stale compiler assets.
    std.Io.Dir.cwd().deleteFile(io, ready) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = marker, .data = "extract compiler inputs" });
    var extraction_argv: [6][]const u8 = undefined;
    var extraction: Extraction = .{
        .io = io,
        .child = try std.process.spawn(io, .{ .argv = extractionStageArgv(&extraction_argv, paths.modules, dump, root, source_directory), .stdin = .ignore }),
    };
    const thread = std.Thread.spawn(.{}, Extraction.wait, .{&extraction}) catch |err| {
        extraction.child.kill(io);
        return err;
    };
    defer thread.join();
    while (true) {
        if (extraction.done.load(.acquire)) {
            if (extraction.failure) |err| return err;
            break;
        }
        if (std.Io.Dir.cwd().access(io, ready, .{})) |_| break else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        try std.Io.sleep(io, .fromMilliseconds(10), .awake);
    }
    // The leaf bitcode was copied from the same build graph as the worker
    // before extraction started. Only the extractor can still occupy a slot.
    const parse_workers = boundedParseWorkers(workers, cpu_limit, !extraction.done.load(.acquire));
    const worker_text = try std.fmt.allocPrint(a, "{d}", .{parse_workers});
    try stage(io, marker, "parse/analyze Lua while finalizing corpus index", &.{ paths.llvm, manifest, root, llvm_dir, "--parse-workers", worker_text, "--value-leaf-bc", leaf_bc });
    // The title index is required by expansion, even if LLVM emission finishes
    // first. The deferred join also covers all error paths.
    while (!extraction.done.load(.acquire)) try std.Io.sleep(io, .fromMilliseconds(10), .awake);
    if (extraction.failure) |err| return err;
}

// Exit code 3 means the immutable cache is absent or its identity differs.
// Every other failure is fatal; a broken helper must not silently fall back.
fn extractionCacheCommand(
    io: std.Io,
    a: std.mem.Allocator,
    action: []const u8,
    options: Options,
    expander_root: []const u8,
    dump: ?[]const u8,
) !bool {
    const helper = try std.fs.path.join(a, &.{ paths.project_root, "compiler", "tools", "extraction_cache.py" });
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(a);
    try argv.appendSlice(a, &.{ "python3", "-I", "-S", "-B", helper, action, options.extraction_cache_root.?, paths.modules, options.verified_dump_sha256.?, options.verified_index_sha256.?, expander_root });
    if (dump) |path| try argv.append(a, path);
    var count_buffer: [20]u8 = undefined;
    if (options.verified_source_pages) |pages| {
        const count = try std.fmt.bufPrint(&count_buffer, "{d}", .{pages});
        try argv.appendSlice(a, &.{ "--verified-source-pages", count });
    }
    var child = try std.process.spawn(io, .{ .argv = argv.items, .stdin = .ignore });
    defer child.kill(io);
    const term = try child.wait(io);
    if (term == .exited and term.exited == 0) return true;
    if (std.mem.eql(u8, action, "probe") and term == .exited and term.exited == 3) return false;
    return error.PipelineStageFailed;
}


// This mode still runs the unchanged ordinary extraction probe. A missing cache
// entry or stale source/ABI/reference is fatal; it never selects an old worker.
fn probeSealedFrontend(io: std.Io, a: std.mem.Allocator, marker: []const u8, options: Options, root: []const u8) !bool {
    const helper = try std.fs.path.join(a, &.{ paths.project_root, "compiler", "tools", "extraction_cache.py" });
    const graph = try std.json.Stringify.valueAlloc(a, .{
        .project_root = paths.project_root, .extractor = paths.modules, .llvm = paths.llvm,
        .runtime = paths.worker_object, .leaf = paths.value_leaf_bc, .main_c = paths.worker_main_c,
        .zig = paths.zig, .clang = paths.clang,
    }, .{});
    try stage(io, marker, "ordinary extraction probe and sealed frontend verification", &.{
        "python3", "-I", "-S", "-B", helper, "probe-sealed-frontend", options.extraction_cache_root.?,
        paths.modules, options.verified_dump_sha256.?, options.verified_index_sha256.?, root,
        options.dump, graph, options.sealed_frontend_reference.?,
    });
    return true;
}

fn objectCacheCommand(
    io: std.Io,
    a: std.mem.Allocator,
    action: []const u8,
    cache_root: []const u8,
    llvm_dir: []const u8,
) !bool {
    const helper = try std.fs.path.join(a, &.{ paths.project_root, "compiler", "tools", "extraction_cache.py" });
    // The program object has its own optimization mode, separate from the
    // per-batch modes recorded in batch-plan.tsv.
    const flags = try std.mem.join(a, ",", &.{ clang_common_flags[0], clang_common_flags[1], clang_common_flags[2], clang_program_mode });
    var child = try std.process.spawn(io, .{ .argv = &.{
        "python3", "-I", "-S", "-B", helper, action, cache_root, paths.clang, paths.project_root, llvm_dir, flags, paths.zig,
    }, .stdin = .ignore });
    defer child.kill(io);
    const term = try child.wait(io);
    if (term == .exited and term.exited == 0) return true;
    if (std.mem.eql(u8, action, "probe-objects") and term == .exited and term.exited == 3) return false;
    return error.PipelineStageFailed;
}

// Keep the authenticated tool digest observations inside this one owned helper.
// It is idle while Clang runs; every failure kills/reaps it without publication.
const ObjectCacheSession = struct {
    child: std.process.Child,

    fn start(io: std.Io, a: std.mem.Allocator, cache_root: []const u8, llvm_dir: []const u8) !ObjectCacheSession {
        const helper = try std.fs.path.join(a, &.{ paths.project_root, "compiler", "tools", "extraction_cache.py" });
        defer a.free(helper);
        const flags = try std.mem.join(a, ",", &.{ clang_common_flags[0], clang_common_flags[1], clang_common_flags[2], clang_program_mode });
        defer a.free(flags);
        return spawn(io, &.{ "python3", "-I", "-S", "-B", helper, "object-session", cache_root, paths.clang, paths.project_root, llvm_dir, flags, paths.zig });
    }

    fn spawn(io: std.Io, argv: []const []const u8) !ObjectCacheSession {
        var child = try std.process.spawn(io, .{ .argv = argv, .stdin = .pipe, .stdout = .pipe });
        errdefer child.kill(io);
        var buffer: [3]u8 = undefined;
        var reader = child.stdout.?.readerStreaming(io, &buffer);
        var response: [3]u8 = undefined;
        reader.interface.readSliceAll(&response) catch return error.PipelineStageFailed;
        if (!std.mem.eql(u8, &response, "O0\n") and !std.mem.eql(u8, &response, "O3\n"))
            return error.PipelineStageFailed;
        return .{ .child = child };
    }

    fn publish(self: *ObjectCacheSession, io: std.Io) !void {
        var buffer: [1]u8 = undefined;
        var writer = self.child.stdin.?.writer(io, &buffer);
        try writer.interface.writeAll("P");
        try writer.interface.flush();
        // The helper requires exactly one byte and EOF before publication.
        self.child.stdin.?.close(io);
        self.child.stdin = null;
        const term = try self.child.wait(io);
        if (term != .exited or term.exited != 0) return error.PipelineStageFailed;
    }
};

fn fileSize(io: std.Io, path: []const u8) !u64 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    return (try file.stat(io)).size;
}

const PinnedReviewedManifest = struct {
    bytes: []u8,
    path: []u8,

    fn deinit(self: PinnedReviewedManifest, a: std.mem.Allocator) void {
        a.free(self.bytes);
        a.free(self.path);
    }

    fn publish(self: PinnedReviewedManifest, io: std.Io, a: std.mem.Allocator, root: []const u8) !void {
        const destination = try std.fs.path.join(a, &.{ root, "reviewed-nonlexical.json" });
        defer a.free(destination);
        // Publish retained bytes, never a reopened source or a symlink target.
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = destination, .data = self.bytes });
    }
};

fn pinReviewedManifest(io: std.Io, a: std.mem.Allocator, source: []const u8, expander_root: []const u8) !PinnedReviewedManifest {
    // Match the native consumer's limit. It alone authenticates manifest semantics.
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, source, a, .limited(4 * 1024 * 1024));
    errdefer a.free(bytes);
    const path = try std.fs.path.join(a, &.{ expander_root, "reviewed-nonlexical.execution.json" });
    errdefer a.free(path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
    return .{ .bytes = bytes, .path = path };
}

fn installSnapshot(io: std.Io, a: std.mem.Allocator, source: []const u8, root: []const u8, name: []const u8) !void {
    const destination = try std.fs.path.join(a, &.{ root, name });
    defer a.free(destination);
    const target = try std.Io.Dir.cwd().realPathFileAlloc(io, source, a);
    defer a.free(target);
    // Snapshot inputs are immutable for the lifetime of a build. A symlink keeps
    // the transient expander tree zero-copy; copyFile is a bounded kernel/stream
    // fallback for platforms or filesystems where symlinks are unavailable.
    if (std.Io.Dir.cwd().symLink(io, target, destination, .{})) |_| return else |_| {}
    try std.Io.Dir.cwd().copyFile(source, .cwd(), destination, io, .{});
}

// The installer and completed-source seal use the same selected payload set.
// The index path is borrowed; the optional sibling paths belong to the caller.
fn pageLanguageSnapshotSources(io: std.Io, a: std.mem.Allocator, selected: ?[]const u8) ![3]?[]const u8 {
    const source = selected orelse return .{ null, null, null };
    if (!std.mem.eql(u8, std.fs.path.basename(source), "page-language.json")) return error.InvalidPageLanguageSource;
    const parent = std.fs.path.dirname(source) orelse ".";
    const raw = try std.fs.path.join(a, &.{ parent, "page-language.raw.json" }); errdefer a.free(raw);
    const html = try std.fs.path.join(a, &.{ parent, "page-language.html" }); errdefer a.free(html);
    try std.Io.Dir.cwd().access(io, source, .{});
    try std.Io.Dir.cwd().access(io, raw, .{});
    const has_html = if (std.Io.Dir.cwd().access(io, html, .{})) |_| true else |err| switch (err) {
        error.FileNotFound => false, else => return err,
    };
    if (!has_html) a.free(html);
    return .{ source, raw, if (has_html) html else null };
}

// Python validates the complete inventory before staging. Native page-language
// validation still owns the source semantics and any required prefix authority.
fn installPageLanguageSnapshot(io: std.Io, a: std.mem.Allocator, source: []const u8, root: []const u8) !void {
    const selected = try pageLanguageSnapshotSources(io, a, source);
    defer for (selected[1..]) |path| { if (path) |value| a.free(value); };
    inline for (.{ "page-language.json", "page-language.raw.json", "page-language.html" }, 0..) |name, i| {
        if (selected[i]) |path| try installSnapshot(io, a, path, root, name);
    }
}

test "extractor overlap reserves only its active compile slot" {
    try std.testing.expectEqual(@as(usize, 4), boundedParseWorkers(4, 4, false));
    try std.testing.expectEqual(@as(usize, 3), boundedParseWorkers(4, 4, true));
    try std.testing.expectEqual(@as(usize, 2), boundedParseWorkers(2, 4, true));
    try std.testing.expectEqual(@as(usize, 1), boundedParseWorkers(4, 1, true));
}

test "snapshot install resolves relative sources before linking" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(base);
    const source = try std.fs.path.join(a, &.{ base, "snapshot.tsv" });
    defer a.free(source);
    const root = try std.fs.path.join(a, &.{ base, "nested", "expander" });
    defer a.free(root);
    try std.Io.Dir.cwd().createDirPath(io, root);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = source, .data = "ok\n" });
    try installSnapshot(io, a, source, root, "snapshot.tsv");
    const installed = try std.fs.path.join(a, &.{ root, "snapshot.tsv" });
    defer a.free(installed);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, installed, a, .limited(16));
    defer a.free(bytes);
    try std.testing.expectEqualStrings("ok\n", bytes);
}

const CompileMode = enum {
    o0,
    o1,
    o2,

    fn parse(raw: []const u8) !CompileMode {
        if (std.mem.eql(u8, raw, "-O0")) return .o0;
        if (std.mem.eql(u8, raw, "-O1")) return .o1;
        if (std.mem.eql(u8, raw, "-O2")) return .o2;
        return error.InvalidBatchPlan;
    }

    fn flag(self: CompileMode) []const u8 {
        return switch (self) {
            .o0 => "-O0",
            .o1 => "-O1",
            .o2 => "-O2",
        };
    }
};

test "batch compile modes preserve explicit flags" {
    const modes = [_]CompileMode{ .o0, .o1, .o2 };
    const flags = [_][]const u8{ "-O0", "-O1", "-O2" };
    for (modes, flags) |mode, flag| {
        try std.testing.expectEqual(mode, try CompileMode.parse(flag));
        try std.testing.expectEqualStrings(flag, mode.flag());
    }
    try std.testing.expectError(error.InvalidBatchPlan, CompileMode.parse("-Ofast"));
    try std.testing.expectError(error.InvalidBatchPlan, CompileMode.parse(""));
}

const BatchPlan = struct {
    mode: CompileMode,
    file: []const u8,
    count: usize,
    first_index: usize,
    last_index: usize,
    source_bytes: u64,
};

fn readBatchPlan(
    io: std.Io,
    a: std.mem.Allocator,
    llvm_dir: []const u8,
) ![]BatchPlan {
    const path = try std.fs.path.join(a, &.{ llvm_dir, "batch-plan.tsv" });
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(64 * 1024 * 1024));

    var plans: std.ArrayList(BatchPlan) = .empty;
    errdefer plans.deinit(a);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        const mode = try CompileMode.parse(
            fields.next() orelse return error.InvalidBatchPlan,
        );
        const file = fields.next() orelse return error.InvalidBatchPlan;
        if (file.len == 0 or
            std.fs.path.isAbsolute(file) or
            std.mem.indexOfScalar(u8, file, '/') != null or
            !std.mem.endsWith(u8, file, ".bc"))
            return error.InvalidBatchPlan;
        const count = try std.fmt.parseInt(
            usize,
            fields.next() orelse return error.InvalidBatchPlan,
            10,
        );
        const first_index = try std.fmt.parseInt(
            usize,
            fields.next() orelse return error.InvalidBatchPlan,
            10,
        );
        const last_index = try std.fmt.parseInt(
            usize,
            fields.next() orelse return error.InvalidBatchPlan,
            10,
        );
        const source_bytes = try std.fmt.parseInt(
            u64,
            fields.next() orelse return error.InvalidBatchPlan,
            10,
        );
        if (fields.next() != null or count == 0 or last_index < first_index)
            return error.InvalidBatchPlan;
        try plans.append(a, .{
            .mode = mode,
            .file = file,
            .count = count,
            .first_index = first_index,
            .last_index = last_index,
            .source_bytes = source_bytes,
        });
    }
    return plans.toOwnedSlice(a);
}

const BatchCompileItem = struct {
    source: []const u8,
    object: []const u8,
    batch_index: usize,
    plan: BatchPlan,
};

fn compileBatch(io: std.Io, item: *const BatchCompileItem) !void {
    const plan = item.plan;
    std.debug.print(
        "dictionary build: compile {s} LLVM batch count={d} first={d} last={d} source_bytes={d}\n",
        .{ plan.mode.flag(), plan.count, plan.first_index, plan.last_index, plan.source_bytes },
    );
    var child = try std.process.spawn(io, .{
        .argv = &.{
            paths.clang,
            plan.mode.flag(),
            clang_common_flags[0],
            clang_common_flags[1],
            clang_common_flags[2],
            "-c",
            item.source,
            "-o",
            item.object,
        },
        .stdin = .ignore,
    });
    // Zig 0.16 Child.kill is idempotent and blocks until this child is reaped.
    // This handles a wait error without leaving a compiler process behind.
    errdefer child.kill(io);
    const started_ns = std.Io.Clock.awake.now(io).toNanoseconds();
    const term = try child.wait(io);
    const elapsed_ms = @divTrunc(std.Io.Clock.awake.now(io).toNanoseconds() - started_ns, std.time.ns_per_ms);
    if (term != .exited or term.exited != 0) {
        std.debug.print(
            "dictionary build failed compiling {s} LLVM batch count={d} first={d} last={d} elapsed_ms={d}; incomplete marker retained\n",
            .{ plan.mode.flag(), plan.count, plan.first_index, plan.last_index, elapsed_ms },
        );
        return error.PipelineStageFailed;
    }
    std.debug.print(
        "dictionary build completed: {s} LLVM batch count={d} first={d} last={d} elapsed_ms={d}\n",
        .{ plan.mode.flag(), plan.count, plan.first_index, plan.last_index, elapsed_ms },
    );
    std.Io.Dir.cwd().deleteFile(io, item.source) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

const BatchCompilePool = struct {
    io: std.Io,
    items: []const BatchCompileItem,
    next: std.atomic.Value(usize) = .init(0),
    stop: std.atomic.Value(bool) = .init(false),
};

const BatchCompileWorker = struct {
    pool: *BatchCompilePool,
    failure: ?anyerror = null,

    fn run(self: *BatchCompileWorker) void {
        while (true) {
            if (self.pool.stop.load(.acquire)) return;
            const index = self.pool.next.fetchAdd(1, .monotonic);
            if (index >= self.pool.items.len or self.pool.stop.load(.acquire)) return;
            compileBatch(self.pool.io, &self.pool.items[index]) catch |err| {
                self.failure = err;
                self.pool.stop.store(true, .release);
                return;
            };
        }
    }
};

fn compileMissingBatches(
    io: std.Io,
    a: std.mem.Allocator,
    items: []const BatchCompileItem,
    llvm_workers: usize,
) !void {
    if (llvm_workers == 0 or llvm_workers > max_parallel_workers) return error.InvalidWorkerCount;
    const worker_count = @min(llvm_workers, items.len);
    std.debug.print("dictionary build: LLVM compile workers={d} missing_batches={d}\n", .{ worker_count, items.len });
    // A full cache hit performs no worker allocation, thread spawn, or Clang
    // invocation. The caller still handles the independent program.o bit.
    if (items.len == 0) return;
    var pool: BatchCompilePool = .{ .io = io, .items = items };
    const workers = try a.alloc(BatchCompileWorker, worker_count);
    defer a.free(workers);
    for (workers) |*worker| worker.* = .{ .pool = &pool };
    // The caller is one of the bounded compiler workers. Thread-spawn failure
    // stops claims and joins all already-started workers before returning.
    const threads = try a.alloc(std.Thread, worker_count - 1);
    defer a.free(threads);
    var started: usize = 0;
    errdefer {
        pool.stop.store(true, .release);
        for (threads[0..started]) |thread| thread.join();
    }
    for (threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, BatchCompileWorker.run, .{&workers[started + 1]});
        started += 1;
    }
    workers[0].run();
    for (threads[0..started]) |thread| thread.join();
    started = 0;
    for (workers) |worker| if (worker.failure) |err| return err;
}

test "empty native compile queue launches no workers" {
    // A failing allocator proves the all-hit branch returns before creating
    // worker/thread storage. No compiler tool is needed by this test.
    try compileMissingBatches(std.testing.io, std.testing.failing_allocator, &.{}, 4);
    try std.testing.expectError(error.InvalidWorkerCount, compileMissingBatches(std.testing.io, std.testing.failing_allocator, &.{}, 0));
    try std.testing.expectError(error.InvalidWorkerCount, compileMissingBatches(std.testing.io, std.testing.failing_allocator, &.{}, 5));
}

test "two failed Clang batches leave no object and join every owned child" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(base);
    const first_source = try std.fs.path.join(a, &.{ base, "invalid-a.bc" });
    defer a.free(first_source);
    const second_source = try std.fs.path.join(a, &.{ base, "invalid-b.bc" });
    defer a.free(second_source);
    const first_object = try std.fs.path.join(a, &.{ base, "invalid-a.o" });
    defer a.free(first_object);
    const second_object = try std.fs.path.join(a, &.{ base, "invalid-b.o" });
    defer a.free(second_object);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = first_source, .data = "invalid LLVM bitcode\n" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = second_source, .data = "invalid LLVM bitcode\n" });
    const plan: BatchPlan = .{ .mode = .o0, .file = "invalid.bc", .count = 1, .first_index = 0, .last_index = 0, .source_bytes = 21 };
    const items = [_]BatchCompileItem{
        .{ .source = first_source, .object = first_object, .batch_index = 0, .plan = plan },
        .{ .source = second_source, .object = second_object, .batch_index = 1, .plan = plan },
    };
    // Each worker owns its own Clang process. The pool returns only after all
    // started workers have waited or killed/reaped their exact child.
    try std.testing.expectError(error.PipelineStageFailed, compileMissingBatches(io, a, &items, 2));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openFile(io, first_object, .{}));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openFile(io, second_object, .{}));
}

fn compileBitcodeModules(
    io: std.Io,
    a: std.mem.Allocator,
    marker: []const u8,
    llvm_dir: []const u8,
    llvm_workers: usize,
    use_object_cache: bool,
    sealed_frontend: bool,
) !std.ArrayList([]const u8) {
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = marker,
        .data = "compile Lua LLVM bitcode batches",
    });

    if (llvm_workers == 0 or llvm_workers > max_parallel_workers) return error.InvalidWorkerCount;
    const plans = try readBatchPlan(io, a, llvm_dir);
    defer a.free(plans);
    const cache_hits = if (use_object_cache) blk: {
        const hits_path = try std.fs.path.join(a, &.{ llvm_dir, ".object-hits" });
        defer a.free(hits_path);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, hits_path, a, .limited(100_002));
        errdefer a.free(bytes);
        if (sealed_frontend) try validateSealedFrontendHits(bytes, plans.len + 1) else try validateObjectHits(bytes, plans.len + 1);
        break :blk bytes;
    } else null;
    defer if (cache_hits) |hits| a.free(hits);
    var objects: std.ArrayList([]const u8) = .empty;
    errdefer objects.deinit(a);
    // All paths and plan metadata are prepared before workers start. Keep
    // every object in current plan order, but enqueue only verified misses.
    const items = try a.alloc(BatchCompileItem, plans.len);
    defer a.free(items);
    var missing_count: usize = 0;
    for (plans, 0..) |plan, batch_index| {
        const source = try std.fs.path.join(a, &.{ llvm_dir, plan.file });
        const object = try std.fmt.allocPrint(a, "{s}/module_batch_{d:0>6}.o", .{ llvm_dir, batch_index });
        try objects.append(a, object);
        // Only the verified probe bitmap authorizes a skip. A cached
        // hardlink must never be passed to Clang as a writable output.
        if (cache_hits) |hits| {
            if (hits[batch_index] == '1') {
                std.Io.Dir.cwd().deleteFile(io, source) catch |err| switch (err) {
                    error.FileNotFound => if (!sealed_frontend) return err,
                    else => return err,
                };
                continue;
            }
        }
        items[missing_count] = .{ .source = source, .object = object, .batch_index = batch_index, .plan = plan };
        missing_count += 1;
    }
    try compileMissingBatches(io, a, items[0..missing_count], llvm_workers);

    const program_source = try std.fs.path.join(a, &.{ llvm_dir, "program.bc" });
    const program_object = try std.fs.path.join(a, &.{ llvm_dir, "program.o" });
    if (cache_hits == null or cache_hits.?[plans.len] == '0')
        try stage(io, marker, "compile LLVM program metadata (-O1)", &.{
            paths.clang,
            clang_program_mode,
            clang_common_flags[0],
            clang_common_flags[1],
            clang_common_flags[2],
            "-c",
            program_source,
            "-o",
            program_object,
        });
    try objects.append(a, program_object);
    std.Io.Dir.cwd().deleteFile(io, program_source) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    return objects;
}

fn validateSealedFrontendHits(bytes: []const u8, object_count: usize) !void {
    try validateObjectHits(bytes, object_count);
    if (std.mem.indexOfScalar(u8, bytes, '0') != null) return error.SealedFrontendObjectMissing;
}

fn validateObjectHits(bytes: []const u8, object_count: usize) !void {
    // One bit per batch plus the final program.o bit. The helper writes this
    // only after hashing and restoring each listed immutable cache object.
    if (object_count < 1 or object_count > 100_001 or
        bytes.len != object_count + 1 or bytes[object_count] != '\n')
        return error.InvalidObjectCacheHits;
    for (bytes[0..object_count]) |byte| {
        if (byte != '0' and byte != '1') return error.InvalidObjectCacheHits;
    }
}

test "object cache hit bitmap is exact and includes the program object" {
    try validateObjectHits("101\n", 3);
    try validateObjectHits("000\n", 3);
    try validateObjectHits("111\n", 3);
    try validateObjectHits("1\n", 1);
    const invalid = [_][]const u8{ "11\n", "1111\n", "10x\n", "101", "101\r", "101\n0" };
    for (invalid) |bytes|
        try std.testing.expectError(error.InvalidObjectCacheHits, validateObjectHits(bytes, 3));
    try std.testing.expectError(error.InvalidObjectCacheHits, validateObjectHits("10\n", 1));
    try std.testing.expectError(error.InvalidObjectCacheHits, validateObjectHits("", 100_002));
}

fn installCachedLeafBitcode(io: std.Io, a: std.mem.Allocator, llvm_dir: []const u8) ![]const u8 {
    const output = try std.fs.path.join(a, &.{ llvm_dir, "value_leaf.bc" });
    // Keep the existing private path used by the frontend and object cache.
    // No reader starts until this copy completes; the source is a generated
    // build artifact paired with the runtime worker, never live Zig source.
    try std.Io.Dir.cwd().copyFile(paths.value_leaf_bc, .cwd(), output, io, .{});
    return output;
}

fn validateCachedBuildInput(io: std.Io, path: []const u8, max_size: u64) !void {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
        std.debug.print("cached native build input unavailable: {s}\n", .{path});
        return err;
    };
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.size == 0 or stat.size > max_size)
        return error.InvalidCachedNativeBuildInput;
}

// The build graph already compiled and content-tracked this repository-only
// object. Never silently rebuild from possibly different live sources when a
// caller invokes an old cached pipeline whose artifact is no longer present.
fn cachedWorkerObject(io: std.Io) ![]const u8 {
    const file = std.Io.Dir.cwd().openFile(io, paths.worker_object, .{}) catch |err| {
        std.debug.print("cached runtime worker object unavailable: {s}\n", .{paths.worker_object});
        return err;
    };
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.size == 0) return error.InvalidCachedWorkerObject;
    std.debug.print("dictionary build: using Zig build runtime worker object {s}\n", .{paths.worker_object});
    return paths.worker_object;
}

fn appendResponseArg(out: *std.ArrayList(u8), a: std.mem.Allocator, arg: []const u8) !void {
    try out.append(a, '"');
    for (arg) |byte| {
        if (byte == '\\' or byte == '"') try out.append(a, '\\');
        try out.append(a, byte);
    }
    try out.appendSlice(a, "\"\n");
}

fn writeResponseFile(io: std.Io, a: std.mem.Allocator, path: []const u8, args: []const []const u8) !void {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(a);
    for (args) |arg| try appendResponseArg(&data, a, arg);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data.items });
}

fn linkNativeWorker(
    io: std.Io,
    a: std.mem.Allocator,
    marker: []const u8,
    llvm_dir: []const u8,
    main_c: []const u8,
    worker: []const u8,
    lua_objects: []const []const u8,
    output: []const u8,
) !void {
    const response_path = try std.fs.path.join(a, &.{ llvm_dir, "module-objects.rsp" });
    try writeResponseFile(io, a, response_path, lua_objects);
    const response_arg = try std.fmt.allocPrint(a, "@{s}", .{response_path});
    try stage(io, marker, "link optimized native Lua worker", &.{
        paths.zig, "cc", "-O2", "-pthread", main_c, worker, response_arg, "-lm", "-lbz2", "-lzstd", "-lc", "-o", output,
    });
}

fn sealPreparedSource(io: std.Io, a: std.mem.Allocator, options: Options, root: []const u8) !void {
    const helper = try std.fs.path.join(a, &.{ paths.project_root, "compiler", "tools", "extraction_cache.py" });
    const graph = try std.json.Stringify.valueAlloc(a, .{
        .project_root = paths.project_root, .extractor = paths.modules, .llvm = paths.llvm,
        .runtime = paths.worker_object, .leaf = paths.value_leaf_bc, .main_c = paths.worker_main_c,
        .zig = paths.zig, .clang = paths.clang,
    }, .{});
    const page_language_sources = try pageLanguageSnapshotSources(io, a, options.page_language_snapshot);
    defer for (page_language_sources[1..]) |path| { if (path) |value| a.free(value); };
    const snapshots = try std.json.Stringify.valueAlloc(a, .{
        .@"namespace-registry.tsv" = options.namespace_registry_snapshot,
        .@"stylesheet-imports.json" = options.stylesheet_imports_snapshot,
        .@"namespace-siteinfo.raw.json" = options.site_info_snapshot,
        .@"page-language.json" = page_language_sources[0],
        .@"page-language.raw.json" = page_language_sources[1],
        .@"page-language.html" = page_language_sources[2],
        .@"figure-siteinfo.raw.json" = options.figure_siteinfo_snapshot,
        .@"figure-sizing.json" = options.figure_sizing_snapshot,
        .@"figure-sizing.raw.json" = options.figure_sizing_raw_snapshot,
        .@"figure-sizing.site.json" = options.figure_sizing_site_snapshot,
        .@"figure-page-observations.json" = options.figure_page_observations_snapshot,
        .@"site-statistics-format.json" = options.site_statistics_format_snapshot,
        .@"commons-data.tsv" = options.commons_data_snapshot,
        .@"category-stats.tsv" = options.category_stats_snapshot,
        .@"category-statistics-format.json" = options.category_statistics_format_snapshot,
        .@"interface-messages.tsv" = options.interface_messages_snapshot,
        .@"category-tree.tsv" = options.category_tree_snapshot,
        .@"interwiki-map.tsv" = options.interwiki_map_snapshot,
        .@"wikibase-sitelinks.tsv" = options.wikibase_sitelinks_snapshot,
        .@"wikibase-entity-text.tsv" = options.wikibase_entity_text_snapshot,
        .@"wikibase-entities.tsv" = options.wikibase_entities_snapshot,
        .@"wikibase-page-links.tsv" = options.wikibase_page_links_snapshot,
        .@"page-redirects.tsv" = options.page_redirects_snapshot,
        .@"wikibase-entity-terms.tsv" = options.wikibase_entity_terms_snapshot,
        .@"language-registry.tsv" = options.language_registry_snapshot,
        .@"language-fallbacks.tsv" = options.language_fallbacks_snapshot,
        .@"date-numbering.tsv" = options.date_numbering_snapshot,
        .@"language-names.tsv" = options.language_names_snapshot,
        .@"image-options.tsv" = options.image_options_snapshot,
        .@"behavior-switches.tsv" = options.behavior_switches_snapshot,
        .@"magic-words.tsv" = options.magic_words_snapshot,
        .@"parser-function-facts.json" = options.parser_function_facts_snapshot,
        .@"file-metadata.tsv" = options.file_metadata_snapshot,
        .@"transclusion-redirects.tsv" = options.transclusion_redirects_snapshot,
    }, .{});
    const argv: []const []const u8 = if (options.sealed_frontend_reference) |reference| &.{
        "python3", "-I", "-S", "-B", helper, "seal-expander", root, options.dump, options.verified_dump_sha256.?,
        options.verified_index_sha256.?, graph, snapshots, reference,
    } else &.{
        "python3", "-I", "-S", "-B", helper, "seal-expander", root, options.dump, options.verified_dump_sha256.?,
        options.verified_index_sha256.?, graph, snapshots,
    };
    var child = try std.process.spawn(io, .{ .argv = argv, .stdin = .ignore });
    defer child.kill(io);
    const term = try child.wait(io);
    if (term == .exited and term.exited == 0) return;
    return error.PipelineStageFailed;
}

fn compileNativeWorker(
    io: std.Io,
    a: std.mem.Allocator,
    marker: []const u8,
    publish_root: []const u8,
    llvm_dir: []const u8,
    llvm_workers: usize,
    object_cache_root: ?[]const u8,
    worker: []const u8,
    options: Options,
) !void {
    var object_session: ?ObjectCacheSession = null;
    defer if (object_session) |*session| session.child.kill(io);
    if (options.sealed_frontend_reference == null) {
        if (object_cache_root) |cache|
            object_session = try ObjectCacheSession.start(io, a, cache, llvm_dir);
    }
    const lua_objects = try compileBitcodeModules(
        io,
        a,
        marker,
        llvm_dir,
        llvm_workers,
        object_cache_root != null,
        options.sealed_frontend_reference != null,
    );
    if (object_session) |*session| {
        try session.publish(io);
    } else if (object_cache_root) |cache| {
        // A sealed frontend has no fresh probe in this invocation.
        _ = try objectCacheCommand(io, a, "publish-objects", cache, llvm_dir);
    }
    const main_c = paths.worker_main_c;
    const output = try std.fs.path.join(a, &.{ publish_root, "dict-bundle-expander" });
    try linkNativeWorker(io, a, marker, llvm_dir, main_c, worker, lua_objects.items, output);

    const metadata_source = try std.fs.path.join(a, &.{ llvm_dir, "program.meta" });
    const metadata_destination = try std.fs.path.join(a, &.{ publish_root, "lua-program.meta" });
    try std.Io.Dir.cwd().rename(metadata_source, std.Io.Dir.cwd(), metadata_destination, io);
    // Preserve batch and per-module plans so runtime profiles can audit the
    // static O0/O1/O2 heuristic after bulky compiler scratch is removed.
    const plan_source = try std.fs.path.join(a, &.{ llvm_dir, "batch-plan.tsv" });
    const plan_destination = try std.fs.path.join(a, &.{ std.fs.path.dirname(publish_root) orelse ".", "compile-plan.tsv" });
    try std.Io.Dir.cwd().copyFile(plan_source, .cwd(), plan_destination, io, .{});
    const module_plan_source = try std.fs.path.join(a, &.{ llvm_dir, "compile-plan.tsv" });
    const module_plan_destination = try std.fs.path.join(a, &.{ std.fs.path.dirname(publish_root) orelse ".", "module-compile-plan.tsv" });
    try std.Io.Dir.cwd().copyFile(module_plan_source, .cwd(), module_plan_destination, io, .{});
    // Explicit custody requests seal actual linked assets before scratch retirement.
    if (options.seal_prepared_source)
        try sealPreparedSource(io, a, options, publish_root);
    // The linked expander and moved program metadata are the only runtime inputs.
    // LLVM plans, bitcode and object files are build-only scratch; remove them
    // before page expansion so they do not inflate peak SSD use for large dumps.
    try std.Io.Dir.cwd().deleteTree(io, llvm_dir);
}

test "default LLVM worker count is one plus one third logical CPUs" {
    try std.testing.expectEqual(@as(usize, 1), defaultLlvmWorkersForCpuCount(1));
    try std.testing.expectEqual(@as(usize, 1), defaultLlvmWorkersForCpuCount(2));
    try std.testing.expectEqual(@as(usize, 2), defaultLlvmWorkersForCpuCount(3));
    try std.testing.expectEqual(@as(usize, 4), defaultLlvmWorkersForCpuCount(12));
}

test "prepared source seal requires explicit expander verified inputs" {
    const digest = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const defaults = try parseOptions(&.{ "dump", "out" });
    try std.testing.expect(!defaults.seal_prepared_source);
    const selected = try parseOptions(&.{ "dump", "out", "--expander-only", "--seal-prepared-source",
        "--extraction-cache-root", "cache", "--verified-dump-sha256", digest, "--verified-index-sha256", digest });
    try std.testing.expect(selected.seal_prepared_source);
    try std.testing.expectError(error.Usage, parseOptions(&.{ "dump", "out", "--seal-prepared-source" }));
    try std.testing.expectError(error.Usage, parseOptions(&.{ "dump", "out", "--expander-only", "--seal-prepared-source" }));
    try std.testing.expectError(error.Usage, parseOptions(&.{ "dump", "out", "--seal-prepared-source", "--seal-prepared-source" }));
}

test "LLVM worker override accepts positive integers only" {
    const options = try parseOptions(&.{ "dump.xml", "out", "--llvm-workers", "4" });
    try std.testing.expectEqual(@as(?usize, 4), options.llvm_workers);
    try std.testing.expectError(
        error.Usage,
        parseOptions(&.{ "dump.xml", "out", "--llvm-workers", "0" }),
    );
    try std.testing.expectError(
        error.Usage,
        parseOptions(&.{ "dump.xml", "out", "--llvm-workers", "5" }),
    );
    try std.testing.expectError(
        error.Usage,
        parseOptions(&.{ "dump.xml", "out", "--llvm-workers", "nope" }),
    );
}

test "extraction cache requires both verified staged input digests" {
    const digest = "0000000000000000000000000000000000000000000000000000000000000000";
    const options = try parseOptions(&.{
        "dump.xml",               "out",  "--extraction-cache-root", "cache",
        "--verified-dump-sha256", digest, "--verified-index-sha256", digest,
    });
    try std.testing.expectEqualStrings("cache", options.extraction_cache_root.?);
    try std.testing.expectError(error.Usage, parseOptions(&.{
        "dump.xml",               "out",  "--extraction-cache-root", "cache",
        "--verified-dump-sha256", digest,
    }));
    try std.testing.expectError(error.Usage, parseOptions(&.{
        "dump.xml",               "out",     "--extraction-cache-root", "cache",
        "--verified-dump-sha256", "invalid", "--verified-index-sha256", digest,
    }));
}

test "supplemental transclusion redirect snapshot option is strict" {
    const options = try parseOptions(&.{ "dump.xml", "out", "--transclusion-redirects-snapshot", "redirects.tsv" });
    try std.testing.expectEqualStrings("redirects.tsv", options.transclusion_redirects_snapshot.?);
    try std.testing.expectError(error.Usage, parseOptions(&.{ "dump.xml", "out", "--transclusion-redirects-snapshot" }));
}

test "expander-only option is strict" {
    const options = try parseOptions(&.{ "dump.xml", "out", "--expander-only" });
    try std.testing.expect(options.expander_only);
    try std.testing.expectError(error.Usage, parseOptions(&.{ "dump.xml", "out", "--expander-only", "--expander-only" }));
}

test "Figure snapshot options require the complete four-role source tuple" {
    const flags = [_][]const u8{
        "--figure-siteinfo-snapshot", "--figure-sizing-snapshot",
        "--figure-sizing-raw-snapshot", "--figure-sizing-site-snapshot",
    };
    var argv: [10][]const u8 = undefined;
    argv[0] = "dump.xml";
    argv[1] = "out";
    for (0..16) |mask| {
        var count: usize = 2;
        for (flags, 0..) |flag, i| {
            if (mask & (@as(usize, 1) << @intCast(i)) == 0) continue;
            argv[count] = flag;
            argv[count + 1] = "source.json";
            count += 2;
        }
        if (mask == 0 or mask == 15) {
            const options = try parseOptions(argv[0..count]);
            try std.testing.expectEqual(mask == 15, options.figure_sizing_snapshot != null);
        } else {
            try std.testing.expectError(error.Usage, parseOptions(argv[0..count]));
        }
    }
    for (flags) |flag| {
        try std.testing.expectError(error.Usage, parseOptions(&.{ "dump.xml", "out", flag }));
        try std.testing.expectError(error.Usage, parseOptions(&.{ "dump.xml", "out", flag, "" }));
        try std.testing.expectError(error.Usage, parseOptions(&.{ "dump.xml", "out", flag, "--expander-only" }));
        try std.testing.expectError(error.Usage, parseOptions(&.{ "dump.xml", "out", flag, "a", flag, "b" }));
    }
}

test "edition title magic snapshot option is strict" {
    const options = try parseOptions(&.{ "dump.xml", "out", "--magic-words-snapshot", "aliases.tsv" });
    try std.testing.expectEqualStrings("aliases.tsv", options.magic_words_snapshot.?);
    try std.testing.expectError(error.Usage, parseOptions(&.{ "dump.xml", "out", "--magic-words-snapshot" }));
    try std.testing.expectError(error.Usage, parseOptions(&.{ "dump.xml", "out", "--magic-words-snapshot", "aliases.tsv", "--magic-words-snapshot", "other.tsv" }));
}

test "structured Wikibase and language fallback snapshot options are strict" {
    const cases = .{
        .{ "--wikibase-entities-snapshot", "wikibase_entities_snapshot" },
        .{ "--wikibase-entity-terms-snapshot", "wikibase_entity_terms_snapshot" },
        .{ "--wikibase-page-links-snapshot", "wikibase_page_links_snapshot" },
        .{ "--page-redirects-snapshot", "page_redirects_snapshot" },
        .{ "--language-fallbacks-snapshot", "language_fallbacks_snapshot" },
        .{ "--language-names-snapshot", "language_names_snapshot" },
        .{ "--date-numbering-snapshot", "date_numbering_snapshot" },
        .{ "--site-info-snapshot", "site_info_snapshot" },
        .{ "--page-language-snapshot", "page_language_snapshot" },
        .{ "--site-statistics-format-snapshot", "site_statistics_format_snapshot" },
        .{ "--category-statistics-format-snapshot", "category_statistics_format_snapshot" },
        .{ "--stylesheet-imports-snapshot", "stylesheet_imports_snapshot" },
    };
    inline for (cases) |case| {
        const options = try parseOptions(&.{ "dump.xml", "out", case[0], "snapshot.tsv" });
        try std.testing.expectEqualStrings("snapshot.tsv", @field(options, case[1]).?);
        try std.testing.expectError(error.Usage, parseOptions(&.{ "dump.xml", "out", case[0] }));
        try std.testing.expectError(error.Usage, parseOptions(&.{ "dump.xml", "out", case[0], "snapshot.tsv", case[0], "other.tsv" }));
    }
    try std.testing.expectError(error.Usage, parseOptions(&.{ "dump.xml", "out", "--page-language-snapshot", "" }));
    try std.testing.expectError(error.Usage, parseOptions(&.{ "dump.xml", "out", "--page-language-snapshot", "--expander-only" }));
}

test "page worker override accepts bounded positive integers only" {
    const options = try parseOptions(&.{ "dump.xml", "out", "--page-workers", "2" });
    try std.testing.expectEqual(@as(usize, 2), options.page_workers);
    try std.testing.expectError(error.Usage, parseOptions(&.{ "dump.xml", "out", "--page-workers", "0" }));
    try std.testing.expectError(error.Usage, parseOptions(&.{ "dump.xml", "out", "--page-workers", "5" }));
    try std.testing.expectError(error.Usage, parseOptions(&.{ "dump.xml", "out", "--page-workers", "nope" }));
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(a);
    const options = parseOptions(argv[1..]) catch {
        std.debug.print("usage: dict-bundle-build DUMP NEW_OUTPUT_DIRECTORY --namespace-registry-snapshot FILE [--site-info-snapshot FILE] [--page-language-snapshot FILE] [--site-statistics-format-snapshot FILE] [--commons-data-snapshot FILE] [--category-stats-snapshot FILE] [--category-statistics-format-snapshot FILE] [--interface-messages-snapshot FILE] [--category-tree-snapshot FILE] [--interwiki-map-snapshot FILE] [--wikibase-sitelinks-snapshot FILE] [--wikibase-entity-text-snapshot FILE] [--wikibase-entities-snapshot FILE] [--wikibase-entity-terms-snapshot FILE] [--wikibase-page-links-snapshot FILE] [--page-redirects-snapshot FILE] [--language-registry-snapshot FILE] [--language-fallbacks-snapshot FILE] [--language-names-snapshot FILE] [--date-numbering-snapshot FILE] [--magic-words-snapshot FILE] [--behavior-switches-snapshot FILE] [--image-options-snapshot FILE] [--file-metadata-snapshot FILE] [--transclusion-redirects-snapshot FILE] [--llvm-workers N] [--parse-workers N] [--page-workers N] [--expansion-timeout-ms N] [--expander-only] [--extraction-cache-root DIR --verified-dump-sha256 HEX --verified-index-sha256 HEX]\n", .{});
        std.debug.print("optional final blob stage input: --reviewed-nonlexical PATH (incompatible with --expander-only)\n", .{});
        std.debug.print("Figure inputs require all four: --figure-siteinfo-snapshot FILE --figure-sizing-snapshot FILE --figure-sizing-raw-snapshot FILE --figure-sizing-site-snapshot FILE\n", .{});
        return error.Usage;
    };
    const dump = options.dump;
    const root = options.root;
    if (root.len == 0 or dump.len == 0) return error.Usage;
    const llvm_workers = options.llvm_workers orelse defaultLlvmWorkers();
    const cpu_limit = @max(@as(usize, 1), @min(max_parallel_workers, std.Thread.getCpuCount() catch 1));
    if (llvm_workers > cpu_limit or options.parse_workers > cpu_limit or options.page_workers > cpu_limit) {
        std.debug.print("worker request exceeds safe host limit of {d}\n", .{cpu_limit});
        return error.ResourceLimit;
    }
    const worker_object = try cachedWorkerObject(init.io);
    try validateCachedBuildInput(init.io, paths.value_leaf_bc, 1024 * 1024);
    try validateCachedBuildInput(init.io, paths.worker_main_c, std.math.maxInt(u64));
    if (std.fs.path.dirname(root)) |parent| if (parent.len != 0)
        try std.Io.Dir.cwd().createDirPath(init.io, parent);
    try std.Io.Dir.cwd().createDir(init.io, root, .default_dir);
    const marker = try std.fs.path.join(a, &.{ root, ".incomplete" });
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = marker, .data = "initializing" });
    const expander_root = try std.fs.path.join(a, &.{ root, ".bundle-expander" });
    try std.Io.Dir.cwd().createDir(init.io, expander_root, .default_dir);
    const expander_marker = try std.fs.path.join(a, &.{ expander_root, ".incomplete" });
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = expander_marker, .data = "building" });
    try installOriginalTransport(init.io, a, options, expander_root);
    // Fail missing/unreadable input before starting extraction. Keep the
    // incomplete marker so the caller still has durable failed-build state.
    try std.Io.Dir.cwd().access(init.io, dump, .{});
    try installSnapshot(init.io, a, options.namespace_registry_snapshot orelse return error.NamespaceRegistryRequired, expander_root, "namespace-registry.tsv");
    if (options.stylesheet_imports_snapshot) |snapshot|
        try installSnapshot(init.io, a, snapshot, expander_root, "stylesheet-imports.json");
    if (options.site_info_snapshot) |snapshot|
        try installSnapshot(init.io, a, snapshot, expander_root, "namespace-siteinfo.raw.json");
    if (options.page_language_snapshot) |snapshot|
        try installPageLanguageSnapshot(init.io, a, snapshot, expander_root);
    if (options.figure_siteinfo_snapshot) |snapshot|
        try installSnapshot(init.io, a, snapshot, expander_root, "figure-siteinfo.raw.json");
    if (options.figure_sizing_snapshot) |snapshot|
        try installSnapshot(init.io, a, snapshot, expander_root, "figure-sizing.json");
    if (options.figure_sizing_raw_snapshot) |snapshot|
        try installSnapshot(init.io, a, snapshot, expander_root, "figure-sizing.raw.json");
    if (options.figure_sizing_site_snapshot) |snapshot|
        try installSnapshot(init.io, a, snapshot, expander_root, "figure-sizing.site.json");
    if (options.figure_page_observations_snapshot) |snapshot|
        try installSnapshot(init.io, a, snapshot, expander_root, "figure-page-observations.json");
    if (options.site_statistics_format_snapshot) |snapshot|
        try installSnapshot(init.io, a, snapshot, expander_root, "site-statistics-format.json");
    if (options.commons_data_snapshot) |snapshot|
        try installSnapshot(init.io, a, snapshot, expander_root, "commons-data.tsv");
    if (options.category_stats_snapshot) |snapshot|
        try installSnapshot(init.io, a, snapshot, expander_root, "category-stats.tsv");
    if (options.category_statistics_format_snapshot) |snapshot|
        try installSnapshot(init.io, a, snapshot, expander_root, "category-statistics-format.json");
    if (options.interface_messages_snapshot) |snapshot|
        try installSnapshot(init.io, a, snapshot, expander_root, "interface-messages.tsv");
    if (options.category_tree_snapshot) |snapshot|
        try installSnapshot(init.io, a, snapshot, expander_root, "category-tree.tsv");
    if (options.interwiki_map_snapshot) |snapshot|
        try installSnapshot(init.io, a, snapshot, expander_root, "interwiki-map.tsv");
    if (options.wikibase_sitelinks_snapshot) |snapshot|
        try installSnapshot(init.io, a, snapshot, expander_root, "wikibase-sitelinks.tsv");
    if (options.wikibase_entity_text_snapshot) |snapshot|
        try installSnapshot(init.io, a, snapshot, expander_root, "wikibase-entity-text.tsv");
    if (options.wikibase_entities_snapshot) |snapshot|
        try installSnapshot(init.io, a, snapshot, expander_root, "wikibase-entities.tsv");
    if (options.wikibase_page_links_snapshot) |snapshot|
        try installSnapshot(init.io, a, snapshot, expander_root, "wikibase-page-links.tsv");
    if (options.page_redirects_snapshot) |snapshot|
        try installSnapshot(init.io, a, snapshot, expander_root, "page-redirects.tsv");
    if (options.wikibase_entity_terms_snapshot) |snapshot|
        try installSnapshot(init.io, a, snapshot, expander_root, "wikibase-entity-terms.tsv");
    if (options.language_registry_snapshot) |snapshot|
        try installSnapshot(init.io, a, snapshot, expander_root, "language-registry.tsv");
    if (options.language_fallbacks_snapshot) |snapshot|
        try installSnapshot(init.io, a, snapshot, expander_root, "language-fallbacks.tsv");
    if (options.date_numbering_snapshot) |snapshot|
        try installSnapshot(init.io, a, snapshot, expander_root, "date-numbering.tsv");
    if (options.language_names_snapshot) |snapshot|
        try installSnapshot(init.io, a, snapshot, expander_root, "language-names.tsv");
    if (options.image_options_snapshot) |snapshot|
        try installSnapshot(init.io, a, snapshot, expander_root, "image-options.tsv");
    if (options.behavior_switches_snapshot) |snapshot|
        try installSnapshot(init.io, a, snapshot, expander_root, "behavior-switches.tsv");
    if (options.parser_function_facts_snapshot) |snapshot|
        try installSnapshot(init.io, a, snapshot, expander_root, "parser-function-facts.json");
    if (options.magic_words_snapshot) |snapshot|
        try installSnapshot(init.io, a, snapshot, expander_root, "magic-words.tsv");
    if (options.file_metadata_snapshot) |snapshot|
        try installSnapshot(init.io, a, snapshot, expander_root, "file-metadata.tsv");
    if (options.transclusion_redirects_snapshot) |snapshot|
        try installSnapshot(init.io, a, snapshot, expander_root, "transclusion-redirects.tsv");

    const llvm_dir = try std.fs.path.join(a, &.{ expander_root, "llvm" });
    try std.Io.Dir.cwd().createDirPath(init.io, llvm_dir);
    const leaf_bc = try installCachedLeafBitcode(init.io, a, llvm_dir);
    const cache_hit = if (options.sealed_frontend_reference != null)
        try probeSealedFrontend(init.io, a, marker, options, expander_root)
    else if (options.extraction_cache_root != null)
        try extractionCacheCommand(init.io, a, "probe", options, expander_root, dump)
    else
        false;
    if (cache_hit and options.sealed_frontend_reference == null) {
        const manifest = try std.fs.path.join(a, &.{ expander_root, "manifest.jsonl" });
        const parse_workers = boundedParseWorkers(options.parse_workers, cpu_limit, false);
        const worker_text = try std.fmt.allocPrint(a, "{d}", .{parse_workers});
        try stage(init.io, marker, "parse/analyze Lua from verified extraction cache", &.{ paths.llvm, manifest, expander_root, llvm_dir, "--parse-workers", worker_text, "--value-leaf-bc", leaf_bc });
    } else if (!cache_hit) {
        try extractAndCompile(init.io, a, marker, dump, expander_root, llvm_dir, options.parse_workers, cpu_limit, leaf_bc, options.bzip2_source_directory);
        // compiler-inputs.ready follows indexed transclusion closure. Publish
        // only after the extractor has exited successfully.
        if (options.extraction_cache_root != null)
            _ = try extractionCacheCommand(init.io, a, "publish", options, expander_root, null);
    }

    // The native worker is a transient bundle compiler. It never belongs in the
    // shipped dictionary; full builds consume it immediately and delete .bundle-expander/.
    try compileNativeWorker(init.io, a, marker, expander_root, llvm_dir, llvm_workers, options.extraction_cache_root, worker_object, options);
    // Keep native build artifacts available if corpus expansion fails. The
    // entire transient tree is deleted together only after successful encoding.
    try std.Io.Dir.cwd().deleteFile(init.io, expander_marker);
    if (options.expander_only) {
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = marker, .data = "expander ready" });
        std.debug.print("bundle expander build complete: {s}\n", .{expander_root});
        return;
    }
    const page_workers_text = try std.fmt.allocPrint(a, "{d}", .{options.page_workers});
    const timeout_text = try std.fmt.allocPrint(a, "{d}", .{options.expansion_timeout_ms orelse expansion_deadline.default_ms});
    const now_text = try std.fmt.allocPrint(a, "{d}", .{options.now_unix orelse std.Io.Clock.real.now(init.io).toSeconds()});
    var blob_argv: [13][]const u8 = undefined;
    const reviewed: ?PinnedReviewedManifest = if (options.reviewed_nonlexical) |source|
        try pinReviewedManifest(init.io, a, source, expander_root)
    else
        null;
    defer if (reviewed) |pinned| pinned.deinit(a);
    try stage(init.io, marker, "expand and encode dictionary blobs", blobStageArgv(
        &blob_argv, options, if (reviewed) |pinned| pinned.path else null,
        expander_root, page_workers_text, timeout_text, now_text,
    ));
    if (reviewed) |pinned| try pinned.publish(init.io, a, root);
    try std.Io.Dir.cwd().deleteTree(init.io, expander_root);
    try std.Io.Dir.cwd().deleteFile(init.io, marker);
    std.debug.print("dictionary build complete: {s}\n", .{root});
}

test "pipeline expansion deadline preserves the default and validates overrides" {
    const defaults = try parseOptions(&.{ "dump.xml", "out" });
    try std.testing.expect(defaults.expansion_timeout_ms == null);
    const configured = try parseOptions(&.{ "dump.xml", "out", "--expansion-timeout-ms", "600000" });
    try std.testing.expectEqual(@as(?u32, 600_000), configured.expansion_timeout_ms);
    try std.testing.expectError(error.Usage, parseOptions(&.{ "dump.xml", "out", "--expansion-timeout-ms" }));
    try std.testing.expectError(error.Usage, parseOptions(&.{ "dump.xml", "out", "--expansion-timeout-ms", "3600001" }));
    try std.testing.expectError(error.Usage, parseOptions(&.{ "dump.xml", "out", "--expansion-timeout-ms", "100", "--expansion-timeout-ms", "200" }));
}

test "reviewed nonlexical manifest rejects missing duplicate and unused arguments" {
    const cases = [_][]const []const u8{
        &.{ "dump.xml", "out", "--reviewed-nonlexical" },
        &.{ "dump.xml", "out", "--reviewed-nonlexical", "" },
        &.{ "dump.xml", "out", "--reviewed-nonlexical", "--expander-only" },
        &.{ "dump.xml", "out", "--reviewed-nonlexical", "one.json", "--reviewed-nonlexical", "two.json" },
        &.{ "dump.xml", "out", "--reviewed-nonlexical", "one.json", "--expander-only" },
        &.{ "dump.xml", "out", "--expander-only", "--reviewed-nonlexical", "one.json" },
    };
    for (cases) |args| try std.testing.expectError(error.Usage, parseOptions(args));
}

test "final blob argv preserves defaults and forwards exact reviewed manifest path" {
    const defaults = try parseOptions(&.{ "dump.xml", "out" });
    var default_buffer: [13][]const u8 = undefined;
    const default_argv = blobStageArgv(&default_buffer, defaults, null, "out/.bundle-expander", "2", "600000", "1791072000");
    const expected = [_][]const u8{
        paths.blobs, "dump.xml", "out", "--expander-root", "out/.bundle-expander",
        "--workers", "2", "--expansion-timeout-ms", "600000", "--now-unix", "1791072000",
    };
    try std.testing.expectEqual(expected.len, default_argv.len);
    for (expected, default_argv) |want, got| try std.testing.expectEqualStrings(want, got);
    const configured = try parseOptions(&.{ "dump.xml", "out", "--reviewed-nonlexical", "reviewed execution manifest.json" });
    var configured_buffer: [13][]const u8 = undefined;
    const configured_argv = blobStageArgv(&configured_buffer, configured, "out/.bundle-expander/reviewed-nonlexical.execution.json", "out/.bundle-expander", "2", "600000", "1791072000");
    try std.testing.expectEqual(@as(usize, 13), configured_argv.len);
    for (expected, configured_argv[0..11]) |want, got| try std.testing.expectEqualStrings(want, got);
    try std.testing.expectEqualStrings("--reviewed-nonlexical", configured_argv[11]);
    try std.testing.expectEqualStrings("out/.bundle-expander/reviewed-nonlexical.execution.json", configured_argv[12]);
}

test "reviewed manifest pinning and publication preserve exact bytes after source changes" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(base);
    const source = try std.fs.path.join(a, &.{ base, "approved.json" });
    defer a.free(source);
    const expander_root = try std.fs.path.join(a, &.{ base, ".bundle-expander" });
    defer a.free(expander_root);
    try std.Io.Dir.cwd().createDirPath(io, expander_root);
    const original = "{\n  \"schema\": \"wikidict.reviewed-nonlexical.v1\"\n}\n";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = source, .data = original });
    const pinned = try pinReviewedManifest(io, a, source, expander_root);
    defer pinned.deinit(a);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = source, .data = "changed" });
    var argv_buffer: [13][]const u8 = undefined;
    const options: Options = .{ .dump = "dump.xml", .root = base, .reviewed_nonlexical = source };
    const argv = blobStageArgv(&argv_buffer, options, pinned.path, expander_root, "1", "600000", "1791072000");
    try std.testing.expectEqualStrings(pinned.path, argv[12]);
    try std.testing.expect(!std.mem.eql(u8, source, argv[12]));
    const consumed = try std.Io.Dir.cwd().readFileAlloc(io, argv[12], a, .limited(4 * 1024 * 1024));
    defer a.free(consumed);
    try std.testing.expectEqualStrings(original, consumed);
    try pinned.publish(io, a, base);
    const published_path = try std.fs.path.join(a, &.{ base, "reviewed-nonlexical.json" });
    defer a.free(published_path);
    const published = try std.Io.Dir.cwd().readFileAlloc(io, published_path, a, .limited(4 * 1024 * 1024));
    defer a.free(published);
    try std.testing.expectEqualStrings(consumed, published);
}

test "pipeline pins explicit build time and rejects invalid duplicate timestamps" {
    const configured = try parseOptions(&.{ "dump.xml", "out", "--now-unix", "1791072000" });
    try std.testing.expectEqual(@as(?i64, 1791072000), configured.now_unix);
    try std.testing.expectError(error.Usage, parseOptions(&.{ "dump.xml", "out", "--now-unix", "0" }));
    try std.testing.expectError(error.Usage, parseOptions(&.{ "dump.xml", "out", "--now-unix", "-1" }));
    try std.testing.expectError(error.Usage, parseOptions(&.{ "dump.xml", "out", "--now-unix", "9223372036854775808" }));
    try std.testing.expectError(error.Usage, parseOptions(&.{ "dump.xml", "out", "--now-unix", "1", "--now-unix", "2" }));
}

test "behavior switch snapshot option is strict" {
    const options = try parseOptions(&.{ "dump.xml", "out", "--behavior-switches-snapshot", "behavior.tsv" });
    try std.testing.expectEqualStrings("behavior.tsv", options.behavior_switches_snapshot.?);
    try std.testing.expectError(error.Usage, parseOptions(&.{ "dump.xml", "out", "--behavior-switches-snapshot" }));
    try std.testing.expectError(error.Usage, parseOptions(&.{ "dump.xml", "out", "--behavior-switches-snapshot", "behavior.tsv", "--behavior-switches-snapshot", "other.tsv" }));
}

test "bundle image option snapshot arguments are strict" {
    const options = try parseOptions(&.{ "dump.xml", "out", "--image-options-snapshot", "image.tsv" });
    try std.testing.expectEqualStrings("image.tsv", options.image_options_snapshot.?);
    try std.testing.expectError(error.Usage, parseOptions(&.{ "dump.xml", "out", "--image-options-snapshot" }));
    try std.testing.expectError(error.Usage, parseOptions(&.{ "dump.xml", "out", "--image-options-snapshot", "image.tsv", "--image-options-snapshot", "other.tsv" }));
}

test "explicit stylesheet snapshot option remains separate and rejects duplicates" {
    const options = try parseOptions(&.{ "dump", "out", "--stylesheet-imports-snapshot", "snapshot.json" });
    try std.testing.expectEqualStrings("snapshot.json", options.stylesheet_imports_snapshot.?);
    try std.testing.expectError(error.Usage, parseOptions(&.{ "dump", "out", "--stylesheet-imports-snapshot", "a", "--stylesheet-imports-snapshot", "b" }));
}

test "parser function facts snapshot option retains explicit input and rejects duplicate or absent arguments" {
    const options = try parseOptions(&.{ "dump.xml", "out", "--parser-function-facts-snapshot", "facts.json" });
    try std.testing.expectEqualStrings("facts.json", options.parser_function_facts_snapshot.?);
    try std.testing.expectError(error.Usage, parseOptions(&.{ "dump.xml", "out", "--parser-function-facts-snapshot" }));
    try std.testing.expectError(error.Usage, parseOptions(&.{ "dump.xml", "out", "--parser-function-facts-snapshot", "" }));
    try std.testing.expectError(error.Usage, parseOptions(&.{ "dump.xml", "out", "--parser-function-facts-snapshot", "--expander-only" }));
    try std.testing.expectError(error.Usage, parseOptions(&.{ "dump.xml", "out", "--parser-function-facts-snapshot", "facts.json", "--parser-function-facts-snapshot", "other.json" }));
}

test "page language snapshot installs complete immutable payload set with optional prefix" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path}); defer a.free(base);
    const absent = try pageLanguageSnapshotSources(io, a, null);
    try std.testing.expectEqualDeep([3]?[]const u8{ null, null, null }, absent);
    // Controlled bytes test the installer, not API or language authority.
    inline for (.{ false, true }) |with_prefix| {
        const source_root = try std.fs.path.join(a, &.{ base, if (with_prefix) "with-prefix" else "without-prefix" }); defer a.free(source_root);
        const destination_root = try std.fs.path.join(a, &.{ base, if (with_prefix) "installed-prefix" else "installed-no-prefix" }); defer a.free(destination_root);
        try std.Io.Dir.cwd().createDirPath(io, source_root);
        try std.Io.Dir.cwd().createDirPath(io, destination_root);
        inline for (.{ "page-language.json", "page-language.raw.json", "page-language.html" }, 0..) |name, i| {
            if (i != 2 or with_prefix) {
                const path = try std.fs.path.join(a, &.{ source_root, name }); defer a.free(path);
                try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = name });
            }
        }
        const source = try std.fs.path.join(a, &.{ source_root, "page-language.json" }); defer a.free(source);
        const selected = try pageLanguageSnapshotSources(io, a, source);
        defer for (selected[1..]) |path| { if (path) |value| a.free(value); };
        try std.testing.expectEqualStrings(source, selected[0].?);
        try std.testing.expectEqual(with_prefix, selected[2] != null);
        inline for (.{ "page-language.raw.json", "page-language.html" }, 1..) |name, i| {
            if (selected[i]) |path| {
                const expected = try std.fs.path.join(a, &.{ source_root, name }); defer a.free(expected);
                try std.testing.expectEqualStrings(expected, path);
            }
        }
        try installPageLanguageSnapshot(io, a, source, destination_root);
        inline for (.{ "page-language.json", "page-language.raw.json", "page-language.html" }, 0..) |name, i| {
            const path = try std.fs.path.join(a, &.{ destination_root, name }); defer a.free(path);
            if (i != 2 or with_prefix) {
                const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(128)); defer a.free(bytes);
                try std.testing.expectEqualStrings(name, bytes);
            } else try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, path, .{}));
        }
    }
}

test "page language snapshot missing raw fails before payload installation" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path}); defer a.free(base);
    const source = try std.fs.path.join(a, &.{ base, "page-language.json" }); defer a.free(source);
    const root = try std.fs.path.join(a, &.{ base, "installed" }); defer a.free(root);
    try std.Io.Dir.cwd().createDirPath(io, root);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = source, .data = "controlled" });
    try std.testing.expectError(error.FileNotFound, installPageLanguageSnapshot(io, a, source, root));
    const installed = try std.fs.path.join(a, &.{ root, "page-language.json" }); defer a.free(installed);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, installed, .{}));
    try std.testing.expectError(error.InvalidPageLanguageSource, installPageLanguageSnapshot(io, a, "other.json", root));
}


test "optional Figure page observations require and preserve the normal four-role tuple" {
    const complete = [_][]const u8{ "dump", "out", "--figure-siteinfo-snapshot", "defaults",
        "--figure-sizing-snapshot", "projection", "--figure-sizing-raw-snapshot", "raw",
        "--figure-sizing-site-snapshot", "site" };
    const missing = try parseOptions(&complete);
    try std.testing.expect(missing.figure_page_observations_snapshot == null);
    const selected = try parseOptions(&(complete ++ .{ "--figure-page-observations-snapshot", "observations.json" }));
    try std.testing.expectEqualStrings("observations.json", selected.figure_page_observations_snapshot.?);
    try std.testing.expectEqualStrings("projection", selected.figure_sizing_snapshot.?);
    try std.testing.expectError(error.Usage, parseOptions(&.{ "dump", "out", "--figure-page-observations-snapshot", "observations.json" }));
    try std.testing.expectError(error.Usage, parseOptions(&(complete ++ .{ "--figure-page-observations-snapshot" })));
    try std.testing.expectError(error.Usage, parseOptions(&(complete ++ .{ "--figure-page-observations-snapshot", "" })));
    try std.testing.expectError(error.Usage, parseOptions(&(complete ++ .{ "--figure-page-observations-snapshot", "--expander-only" })));
    try std.testing.expectError(error.Usage, parseOptions(&(complete ++ .{ "--figure-page-observations-snapshot", "a", "--figure-page-observations-snapshot", "b" })));
}

test "normal retained MG preparation preserves every selected emitted argument" {
    const options = try parseOptions(&.{
        "/mnt/downloads/dev/wikidict/data/corpus-campaign-current01/artifacts/dictionaries-native61-mg-current12-01/mgwiktionary/20261001.shards/input/pages.xml.zst",
        "/mnt/downloads/dev/wikidict/data/corpus-executions/native227-mg-current01/expander-current359-sealed02/expander",
        "--expander-only",
        "--interwiki-map-snapshot",
        "/mnt/downloads/dev/wikidict/data/build-receipts-20261011-recovery-loss02/semantic-audit/correctness-composition01/pending-interwiki198-input-selection01/staged-auxiliary/mgwiktionary/interwiki-map.tsv",
        "--behavior-switches-snapshot",
        "/mnt/downloads/dev/wikidict/data/build-receipts-20261011-recovery-loss02/semantic-audit/correctness-composition01/pending-interwiki198-input-selection01/staged-auxiliary/mgwiktionary/behavior-switches.tsv",
        "--category-statistics-format-snapshot",
        "/mnt/downloads/dev/wikidict/data/build-receipts-20261011-recovery-loss02/semantic-audit/correctness-composition01/pending-interwiki198-input-selection01/staged-auxiliary/mgwiktionary/category-statistics-format-v1/category-statistics-format.json",
        "--category-stats-snapshot",
        "/mnt/downloads/dev/wikidict/data/build-receipts-20261011-recovery-loss02/semantic-audit/correctness-composition01/pending-interwiki198-input-selection01/staged-auxiliary/mgwiktionary/category-stats.tsv",
        "--category-tree-snapshot",
        "/mnt/downloads/dev/wikidict/data/build-receipts-20261011-recovery-loss02/semantic-audit/correctness-composition01/pending-interwiki198-input-selection01/staged-auxiliary/mgwiktionary/category-tree.tsv",
        "--date-numbering-snapshot",
        "/mnt/downloads/dev/wikidict/data/build-receipts-20261011-recovery-loss02/semantic-audit/correctness-composition01/pending-interwiki198-input-selection01/staged-auxiliary/mgwiktionary/date-numbering/date-numbering.tsv",
        "--figure-siteinfo-snapshot",
        "/mnt/downloads/dev/wikidict/data/build-receipts-20261011-recovery-loss02/semantic-audit/correctness-composition01/pending-interwiki198-input-selection01/staged-auxiliary/mgwiktionary/figure-inputs/figure-siteinfo.raw.json",
        "--figure-sizing-snapshot",
        "/mnt/downloads/dev/wikidict/data/build-receipts-20261011-recovery-loss02/semantic-audit/correctness-composition01/pending-interwiki198-input-selection01/staged-auxiliary/mgwiktionary/figure-inputs/figure-sizing.json",
        "--figure-sizing-raw-snapshot",
        "/mnt/downloads/dev/wikidict/data/build-receipts-20261011-recovery-loss02/semantic-audit/correctness-composition01/pending-interwiki198-input-selection01/staged-auxiliary/mgwiktionary/figure-inputs/figure-sizing.raw.json",
        "--figure-sizing-site-snapshot",
        "/mnt/downloads/dev/wikidict/data/build-receipts-20261011-recovery-loss02/semantic-audit/correctness-composition01/pending-interwiki198-input-selection01/staged-auxiliary/mgwiktionary/figure-inputs/figure-sizing.site.json",
        "--file-metadata-snapshot",
        "/mnt/downloads/dev/wikidict/data/build-receipts-20261011-recovery-loss02/semantic-audit/correctness-composition01/pending-interwiki198-input-selection01/staged-auxiliary/mgwiktionary/figure-inputs/file-metadata.tsv",
        "--image-options-snapshot",
        "/mnt/downloads/dev/wikidict/data/build-receipts-20261011-recovery-loss02/semantic-audit/correctness-composition01/pending-interwiki198-input-selection01/staged-auxiliary/mgwiktionary/image-options.tsv",
        "--interface-messages-snapshot",
        "/mnt/downloads/dev/wikidict/.tmp/renderer-core-oct28/mg-interface-message-source01/complete-generation01/interface-messages.tsv",
        "--language-fallbacks-snapshot",
        "/mnt/downloads/dev/wikidict/.tmp/renderer-core-oct28/mg-interface-message-source01/complete-generation01/language-fallbacks.tsv",
        "--language-names-snapshot",
        "/mnt/downloads/dev/wikidict/data/build-receipts-20261011-recovery-loss02/semantic-audit/correctness-composition01/pending-interwiki198-input-selection01/staged-auxiliary/mgwiktionary/language-names-autonyms-v1/language-names.tsv",
        "--language-registry-snapshot",
        "/mnt/downloads/dev/wikidict/data/corpus-campaign-current02/downloads/mgwiktionary/20261001/language-registry.tsv",
        "--magic-words-snapshot",
        "/mnt/downloads/dev/wikidict/data/build-receipts-20261011-recovery-loss02/semantic-audit/correctness-composition01/pending-interwiki198-input-selection01/staged-auxiliary/mgwiktionary/magic-words-category-v1/magic-words.tsv",
        "--namespace-registry-snapshot",
        "/mnt/downloads/dev/wikidict/data/build-receipts-20261011-recovery-loss02/semantic-audit/correctness-composition01/pending-interwiki198-input-selection01/staged-auxiliary/mgwiktionary/namespace-registry.tsv",
        "--page-redirects-snapshot",
        "/mnt/downloads/dev/wikidict/data/corpus-executions/native227-mg-current01/output-next306-01/mgwiktionary/20261001.shards/derived-page-redirects/page-redirects.tsv",
        "--site-info-snapshot",
        "/mnt/downloads/dev/wikidict/data/build-receipts-20261011-recovery-loss02/semantic-audit/correctness-composition01/pending-interwiki198-input-selection01/staged-auxiliary/mgwiktionary/site-info/namespace-siteinfo.raw.json",
        "--site-statistics-format-snapshot",
        "/mnt/downloads/dev/wikidict/data/build-receipts-20261011-recovery-loss02/semantic-audit/correctness-composition01/pending-interwiki198-input-selection01/staged-auxiliary/mgwiktionary/site-statistics-format-v1/site-statistics-format.json",
        "--wikibase-page-links-snapshot",
        "/mnt/downloads/dev/wikidict/data/corpus-executions/native227-mg-current01/output-next306-01/mgwiktionary/20261001.shards/derived-page-links/wikibase-page-links.tsv",
        "--llvm-workers",
        "2",
        "--parse-workers",
        "4",
        "--page-workers",
        "4",
        "--seal-prepared-source",
        "--extraction-cache-root",
        "/mnt/downloads/dev/wikidict/data/corpus-executions/native227-mg-current01/cache",
        "--verified-dump-sha256",
        "2da58ab2e1166cb1f4a2beb4e9061fbf9e1302261c8f4506823d15b5d85623de",
        "--verified-index-sha256",
        "9cb777df134f7f9ab463d334f131049c47fe8e9441aaac2c90e6e366d6534486",
    });
    try std.testing.expect(options.expander_only and options.seal_prepared_source);
    try std.testing.expect(options.figure_siteinfo_snapshot != null and options.figure_sizing_snapshot != null and options.figure_sizing_raw_snapshot != null and options.figure_sizing_site_snapshot != null);
    try std.testing.expect(options.figure_page_observations_snapshot == null);
}

test "Figure snapshot installation preserves all five selected role payloads" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path}); defer a.free(base);
    const destination = try std.fs.path.join(a, &.{ base, "installed" }); defer a.free(destination);
    try std.Io.Dir.cwd().createDirPath(io, destination);
    inline for (.{ "figure-siteinfo.raw.json", "figure-sizing.json", "figure-sizing.raw.json", "figure-sizing.site.json", "figure-page-observations.json" }) |name| {
        const source = try std.fs.path.join(a, &.{ base, name }); defer a.free(source);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = source, .data = name });
        try installSnapshot(io, a, source, destination, name);
        const installed = try std.fs.path.join(a, &.{ destination, name }); defer a.free(installed);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, installed, a, .limited(128)); defer a.free(bytes);
        try std.testing.expectEqualStrings(name, bytes);
    }
}


test "sealed frontend option requires explicit ordinary sealing and refuses duplicate or absent reference" {
    const base = [_][]const u8{ "dump", "out", "--expander-only", "--seal-prepared-source",
        "--extraction-cache-root", "cache", "--verified-dump-sha256", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "--verified-index-sha256", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" };
    const selected = try parseOptions(&(base ++ .{ "--sealed-frontend-reference", "{reference}" }));
    try std.testing.expectEqualStrings("{reference}", selected.sealed_frontend_reference.?);
    try std.testing.expectError(error.Usage, parseOptions(&(base ++ .{ "--sealed-frontend-reference" })));
    try std.testing.expectError(error.Usage, parseOptions(&(base ++ .{ "--sealed-frontend-reference", "" })));
    try std.testing.expectError(error.Usage, parseOptions(&(base ++ .{ "--sealed-frontend-reference", "--unknown" })));
    try std.testing.expectError(error.Usage, parseOptions(&(base ++ .{ "--sealed-frontend-reference", "one", "--sealed-frontend-reference", "two" })));
    try std.testing.expectError(error.Usage, parseOptions(&.{ "dump", "out", "--sealed-frontend-reference", "one" }));
}

test "sealed frontend bitmap permits only exact fully verified native object hits" {
    try validateSealedFrontendHits("111\n", 3);
    try std.testing.expectError(error.SealedFrontendObjectMissing, validateSealedFrontendHits("101\n", 3));
    try std.testing.expectError(error.SealedFrontendObjectMissing, validateSealedFrontendHits("110\n", 3));
    try std.testing.expectError(error.InvalidObjectCacheHits, validateSealedFrontendHits("11\n", 3));
    try std.testing.expectError(error.InvalidObjectCacheHits, validateSealedFrontendHits("11x\n", 3));
    // Ordinary cache misses retain their original protocol.
    try validateObjectHits("101\n", 3);
}


test "object cache session publishes once after readiness and joins its owned helper" {
    const io = std.testing.io;
    for ([_][]const u8{ "O0\n", "O3\n" }) |ready| {
        const script = try std.fmt.allocPrint(std.testing.allocator,
            "import sys;sys.stdout.buffer.write({s});sys.stdout.buffer.flush();assert sys.stdin.buffer.read()==b'P'",
            .{if (ready[1] == '0') "b'O0\\n'" else "b'O3\\n'"});
        defer std.testing.allocator.free(script);
        var session = try ObjectCacheSession.spawn(io, &.{ "python3", "-I", "-S", "-B", "-c", script });
        defer session.child.kill(io);
        try session.publish(io);
        try std.testing.expect(session.child.id == null);
        try std.testing.expect(session.child.stdin == null and session.child.stdout == null);
    }
}

test "object cache session refuses invalid readiness and failed publication" {
    const io = std.testing.io;
    try std.testing.expectError(error.PipelineStageFailed, ObjectCacheSession.spawn(io, &.{
        "python3", "-I", "-S", "-B", "-c", "import sys;sys.stdout.buffer.write(b'O4\\n');sys.stdout.buffer.flush();sys.stdin.buffer.read()",
    }));
    try std.testing.expectError(error.PipelineStageFailed, ObjectCacheSession.spawn(io, &.{
        "python3", "-I", "-S", "-B", "-c", "import sys;sys.stdout.buffer.write(b'O');sys.exit(1)",
    }));
    var session = try ObjectCacheSession.spawn(io, &.{
        "python3", "-I", "-S", "-B", "-c", "import sys;sys.stdout.buffer.write(b'O3\\n');sys.stdout.buffer.flush();assert sys.stdin.buffer.read()==b'P';sys.exit(1)",
    });
    defer session.child.kill(io);
    try std.testing.expectError(error.PipelineStageFailed, session.publish(io));
    try std.testing.expect(session.child.id == null);
}

test "abandoned object cache session is killed and reaped without publication" {
    const io = std.testing.io;
    var session = try ObjectCacheSession.spawn(io, &.{
        "python3", "-I", "-S", "-B", "-c", "import sys;sys.stdout.buffer.write(b'O3\\n');sys.stdout.buffer.flush();assert sys.stdin.buffer.read()==b'P';raise RuntimeError('must not publish')",
    });
    // This is the same unconditional cleanup used around compilation failures.
    session.child.kill(io);
    try std.testing.expect(session.child.id == null);
    try std.testing.expect(session.child.stdin == null and session.child.stdout == null);
    session.child.kill(io); // Cleanup after a joined child is harmless.
}


test "archive extraction cache accepts a verified page count including zero" {
    const base = [_][]const u8{ "/original/blocks.json", "/work/new", "--bzip2-source-directory", "/original/parts", "--extraction-cache-root", "cache", "--verified-dump-sha256", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "--verified-index-sha256", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" };
    try std.testing.expect((try parseOptions(&base)).verified_source_pages == null);
    try std.testing.expectEqual(@as(?u64, 0), (try parseOptions(&(base ++ .{ "--verified-source-pages", "0" }))).verified_source_pages);
    try std.testing.expectEqual(@as(?u64, 1118), (try parseOptions(&(base ++ .{ "--verified-source-pages", "1118" }))).verified_source_pages);
    for ([_][]const u8{ "", "-1", "+2", "1_118", "18446744073709551616" }) |invalid| {
        const args = base ++ [_][]const u8{ "--verified-source-pages", invalid };
        try std.testing.expectError(error.Usage, parseOptions(&args));
    }
    try std.testing.expectError(error.Usage, parseOptions(&(base ++ .{"--verified-source-pages"})));
    try std.testing.expectError(error.Usage, parseOptions(&(base ++ .{ "--verified-source-pages", "0", "--verified-source-pages", "1" })));
    try std.testing.expectError(error.Usage, parseOptions(&.{ "/original/blocks.json", "/work/new", "--bzip2-source-directory", "/original/parts", "--verified-source-pages", "1118" }));
}

test "original archive caller keeps descriptor and extractor Writer flags explicit" {
    const a = std.testing.allocator;
    const options = try parseOptions(&.{ "/original/blocks.json", "/work/new", "--bzip2-source-directory", "/original/parts" });
    const bytes = try originalTransportDescriptorBytes(a, options);
    defer a.free(bytes);
    const descriptor = try std.json.parseFromSlice(struct { format: []const u8, transport: []const u8, block_directory: []const u8, source_directory: []const u8 }, a, bytes, .{});
    defer descriptor.deinit();
    try std.testing.expectEqualStrings("wikidict-source-transport-v1", descriptor.value.format);
    try std.testing.expectEqualStrings("bzip2-blocks", descriptor.value.transport);
    try std.testing.expectEqualStrings("/original/blocks.json", descriptor.value.block_directory);
    try std.testing.expectEqualStrings("/original/parts", descriptor.value.source_directory);
    var extraction: [6][]const u8 = undefined;
    const expected = [_][]const u8{ "module-extract-token", "/original/blocks.json", "/work/expander", "--page-index", "--bzip2-source-directory", "/original/parts" };
    const selected = extractionStageArgv(&extraction, "module-extract-token", options.dump, "/work/expander", options.bzip2_source_directory);
    try std.testing.expectEqual(@as(usize, expected.len), selected.len);
    for (expected, selected) |wanted, actual| try std.testing.expectEqualStrings(wanted, actual);
    try std.testing.expectEqual(@as(usize, 4), extractionStageArgv(&extraction, "module-extract-token", "legacy.xml", "legacy-root", null).len);
    var blob: [13][]const u8 = undefined;
    const argv = blobStageArgv(&blob, options, null, "/work/expander", "1", "600000", "100");
    try std.testing.expectEqualStrings("/original/blocks.json", argv[1]);
    try std.testing.expectEqualStrings("--bzip2-source-directory", argv[11]);
    try std.testing.expectEqualStrings("/original/parts", argv[12]);
    try std.testing.expectError(error.Usage, parseOptions(&.{ "relative.json", "/work/new", "--bzip2-source-directory", "/original/parts" }));
    try std.testing.expectError(error.Usage, parseOptions(&.{ "/original/blocks.json", "/work/new", "--bzip2-source-directory", "relative" }));
    try std.testing.expectError(error.Usage, parseOptions(&.{ "/original/blocks.json", "/work/new", "--bzip2-source-directory", "/original/parts", "--bzip2-source-directory", "/elsewhere" }));
    try std.testing.expectError(error.Usage, parseOptions(&.{ "/original/blocks.json", "/work/new", "--bzip2-source-directory", "/original/parts", "--reviewed-nonlexical", "legacy-evidence" }));
}


test "archive descriptor precedes cache probe and refuses fabricated virtual identities" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "blocks.json", .data = @import("wikimedia_dump").OriginalBzipTestData.directory });
    try tmp.dir.createDir(io, "work", .default_dir);
    var buffer: [4096]u8 = undefined;
    const root = buffer[0..try tmp.dir.realPath(io, &buffer)];
    const input = try std.fs.path.join(a, &.{ root, "blocks.json" });
    defer a.free(input);
    const work = try std.fs.path.join(a, &.{ root, "work" });
    defer a.free(work);
    const descriptor = try std.fs.path.join(a, &.{ work, "source-transport.json" });
    defer a.free(descriptor);
    var options: Options = .{ .dump = input, .root = work, .bzip2_source_directory = root };
    try installOriginalTransport(io, a, options, work);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, descriptor, a, .limited(16 * 1024));
    defer a.free(bytes);
    const expected = try originalTransportDescriptorBytes(a, options);
    defer a.free(expected);
    try std.testing.expectEqualStrings(expected, bytes);
    const zeros = "0000000000000000000000000000000000000000000000000000000000000000";
    options.extraction_cache_root = "/not-opened-cache";
    options.verified_dump_sha256 = zeros;
    options.verified_index_sha256 = zeros;
    try std.testing.expectError(error.MissingBzip2Bridge, installOriginalTransport(io, a, options, work));
    try tmp.dir.writeFile(io, .{ .sub_path = "blocks.json", .data = "{\"format\":\"wikidict-bzip2-blocks-v1\",\"zstd_frame_bridge\":{\"dump_bytes\":1,\"offset_index_bytes\":1,\"dump_sha256\":\"different\",\"offset_index_sha256\":\"different\"}}" });
    try std.testing.expectError(error.Bzip2BridgeIdentityMismatch, installOriginalTransport(io, a, options, work));
    const after = try std.Io.Dir.cwd().readFileAlloc(io, descriptor, a, .limited(16 * 1024));
    defer a.free(after);
    try std.testing.expectEqualStrings(bytes, after);
    options.bzip2_source_directory = null;
    options.dump = "/legacy-input-not-opened";
    try installOriginalTransport(io, a, options, "/legacy-root-not-opened");
}
