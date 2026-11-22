import gzip
import importlib.util
import json
import tempfile
import unittest
from unittest import mock
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "extraction_cache", Path(__file__).with_name("extraction_cache.py"))
cache = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cache)


class ExtractionCacheTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.source = self.base / "source"
        self.source.mkdir()
        (self.source / "modules").mkdir()
        (self.source / "modules" / "123.lua").write_text("return 1")
        for name in cache.FILES:
            (self.source / name).write_bytes(name.encode())
        (self.source / "compiler-inputs.ready").write_bytes(b"complete\n")
        (self.source / "dump-streams.tsv").write_bytes(b"0\t0\t100\n")
        (self.source / "page-index.tsv").write_bytes(b"0\t0\t10\tTemplate:fixture\n")
        self.root = self.base / "cache"
        self.expected = {"version": 4, "extractor_args": list(cache.EXTRACTOR_ARGS),
                         "namespace_registry_sha256": "f" * 64,
                         "transclusion_redirects_sha256": None, "page_redirects_sha256": None,
                         "unicode_case": {"libraries": []}, "dump_sha256": "a" * 64,
                         "index_sha256": "d" * 64,
                         "tool": {"extractor_sha256": "b" * 64, "libraries": []}}

    def snapshot_output(self, output, backing, *, copied=False):
        output.mkdir(exist_ok=True)
        (output / "namespace-registry.tsv").write_bytes(b"namespace fixture")
        destination = output / "page-redirects.tsv"
        if copied:
            destination.write_bytes(backing.read_bytes())
        else:
            destination.symlink_to(backing)
        return destination

    def snapshot_main(self, action, output, *extra):
        with mock.patch.object(cache, "tool_identity", return_value=self.expected["tool"]), \
             mock.patch.object(cache, "unicode_case_identity", return_value={"libraries": []}):
            return cache.main(["extraction_cache.py", action, str(self.root),
                               "extractor", "a" * 64, "d" * 64, str(output), *map(str, extra)])

    def test_probe_rejects_relocated_dump_or_index_before_staging(self):
        dump = self.base / 'pages.zst'
        dump.write_bytes(b'verified dump')
        backing = self.base / 'redirects.tsv'
        backing.write_bytes(b'redirect snapshot')
        self.snapshot_output(self.source, backing)
        receipt = dict(version=2, source=cache._receipt_identity(dump), indexes=cache._receipt_indexes(self.source))
        (self.source / 'extraction-source.json').write_text(json.dumps(receipt))
        self.assertEqual(0, self.snapshot_main('publish', self.source))
        generation, = [p for p in self.root.iterdir() if not p.name.startswith('.')]
        marker = (generation / '.complete.json').read_bytes()
        relocated = self.base / 'other-pages.zst'
        relocated.write_bytes(dump.read_bytes())
        output = self.base / 'other-output'
        self.snapshot_output(output, backing)
        before = set(output.iterdir())
        self.assertEqual(cache.MISS, self.snapshot_main('probe', output, relocated))
        self.assertEqual(before, set(output.iterdir()))
        supported = self.base / 'matching-output'
        self.snapshot_output(supported, backing)
        self.assertEqual(0, self.snapshot_main('probe', supported, dump))
        self.assertEqual(b'return 1', (supported / 'modules/123.lua').read_bytes())
        index = generation / 'page-index.tsv'
        replacement = self.base / 'replacement-index'
        replacement.write_bytes(index.read_bytes())
        replacement.replace(index)
        self.assertEqual(cache.MISS, self.snapshot_main('probe', output, dump))
        self.assertEqual(before, set(output.iterdir()))
        self.assertEqual(marker, (generation / '.complete.json').read_bytes())

    def test_snapshot_main_cold_publish_warm_link_and_copy(self):
        backing = self.base / "redirects.tsv"
        backing.write_bytes(b"exact redirect snapshot")
        installed = self.snapshot_output(self.source, backing)
        self.assertEqual(cache.MISS, self.snapshot_main("probe", self.source))
        self.assertEqual(0, self.snapshot_main("publish", self.source))
        generation, = [p for p in self.root.iterdir() if not p.name.startswith(".")]
        marker = cache.read_marker(generation / ".complete.json")
        self.assertEqual(cache.sha256(backing), marker["identity"]["page_redirects_sha256"])
        self.assertNotIn("page-redirects.tsv", cache.FILES)
        self.assertFalse((generation / "page-redirects.tsv").exists())
        for name in cache.walk_assets(generation):
            self.assertFalse((generation / name).is_symlink(), name)
        self.assertTrue(installed.is_symlink())
        for copied in (False, True):
            with self.subTest(copied=copied):
                output = self.base / ("copy" if copied else "linked")
                sidecar = self.snapshot_output(output, backing, copied=copied)
                self.assertEqual(0, self.snapshot_main("probe", output))
                self.assertEqual(not copied, sidecar.is_symlink())
                self.assertEqual(backing.read_bytes(), sidecar.read_bytes())
                self.assertEqual(b"return 1", (output / "modules/123.lua").read_bytes())

    def test_warm_probe_links_the_verified_inventory_in_one_walk(self):
        module = self.source / 'modules' / 'nested' / 'helper.lua'
        module.parent.mkdir()
        module.write_bytes(b'return 2')
        self.assertEqual(0, cache.publish(self.root, self.expected, self.source))
        generation, = self.root.iterdir()
        output = self.base / 'restored'
        output.mkdir()
        with mock.patch.object(cache, 'walk_assets', wraps=cache.walk_assets) as walk:
            self.assertEqual(0, cache.probe(self.root, self.expected, output))
        walk.assert_called_once_with(generation)
        for name, _, _ in cache.read_marker(generation / '.complete.json')['assets']:
            self.assertTrue((generation / name).samefile(output / name), name)

    def test_module_inventory_refuses_unreadable_subtree(self):
        nested = self.source / 'modules' / 'level'
        nested.mkdir()
        (nested / 'helper.lua').write_bytes(b'return 2')
        scandir = cache.os.scandir

        def fail_nested(path):
            if Path(path) == nested:
                raise PermissionError('Cannot enumerate fixture subtree')
            return scandir(path)

        with mock.patch.object(cache.os, 'scandir', side_effect=fail_nested):
            with self.assertRaises(PermissionError):
                cache.walk_assets(self.source)

    def test_module_inventory_rejects_links_and_special_files(self):
        modules = self.source / 'modules'
        nested = modules / 'level'
        nested.mkdir()
        alias = modules / 'alias'
        for target in (nested, modules / '123.lua', modules / 'missing'):
            with self.subTest(target=target):
                alias.symlink_to(target)
                with self.assertRaises(ValueError):
                    cache.walk_assets(self.source)
                alias.unlink()
        cache.os.mkfifo(alias)
        with self.assertRaises(ValueError):
            cache.walk_assets(self.source)

    def test_snapshot_backing_mutation_invalidates_main_probe(self):
        backing = self.base / "redirects.tsv"
        backing.write_bytes(b"snapshot before")
        self.snapshot_output(self.source, backing)
        self.assertEqual(0, self.snapshot_main("publish", self.source))
        backing.write_bytes(b"snapshot after")
        output = self.base / "changed"
        self.snapshot_output(output, backing)
        self.assertEqual(cache.MISS, self.snapshot_main("probe", output))
        self.assertFalse((output / "modules").exists())
        self.assertTrue(all(not (output / name).exists() for name in cache.FILES))

    def test_snapshot_dangling_and_directory_links_are_not_absent(self):
        for kind in ("dangling", "directory"):
            with self.subTest(kind=kind):
                backing = self.base / (kind + "-target")
                if kind == "directory":
                    backing.mkdir()
                output = self.base / kind
                self.snapshot_output(output, backing)
                with self.assertRaises((FileNotFoundError, ValueError)):
                    self.snapshot_main("probe", output)
                self.assertFalse(self.root.exists())

    def test_snapshot_input_resolution_does_not_allow_symlink_cache_assets(self):
        backing = self.base / "redirects.tsv"
        backing.write_bytes(b"snapshot")
        self.snapshot_output(self.source, backing)
        self.assertEqual(0, self.snapshot_main("publish", self.source))
        generation, = [p for p in self.root.iterdir() if not p.name.startswith(".")]
        external = self.base / "external-page-index.tsv"
        external.write_bytes((generation / "page-index.tsv").read_bytes())
        (generation / "page-index.tsv").unlink()
        (generation / "page-index.tsv").symlink_to(external)
        output = self.base / "corrupt-cache"
        self.snapshot_output(output, backing)
        self.assertEqual(cache.MISS, self.snapshot_main("probe", output))
        self.assertFalse((output / "modules").exists())
        (self.source / "page-index.tsv").unlink()
        (self.source / "page-index.tsv").symlink_to(external)
        with self.assertRaisesRegex(ValueError, "Expected regular extraction asset"):
            self.snapshot_main("publish", self.source)

    def test_round_trip_and_corruption(self):
        self.assertEqual(0, cache.publish(self.root, self.expected, self.source))
        output = self.base / "output"
        output.mkdir()
        self.assertEqual(0, cache.probe(self.root, self.expected, output))
        self.assertEqual(b"return 1", (output / "modules" / "123.lua").read_bytes())
        self.assertEqual((self.source / "page-index.tsv").read_bytes(),
                         (output / "page-index.tsv").read_bytes())
        (output / "page-index.tsv").write_bytes(b"corrupt")
        other = self.base / "other"
        other.mkdir()
        self.assertEqual(cache.MISS, cache.probe(self.root, self.expected, other))
        self.assertFalse((other / "modules").exists())

    def test_extractor_identity_change_is_miss(self):
        cache.publish(self.root, self.expected, self.source)
        changed = dict(self.expected, tool={"extractor_sha256": "c" * 64,
                                            "libraries": []})
        output = self.base / "other"
        output.mkdir()
        self.assertEqual(cache.MISS, cache.probe(self.root, changed, output))
        changed_index = dict(self.expected, index_sha256="e" * 64)
        self.assertEqual(cache.MISS, cache.probe(self.root, changed_index, output))

    def test_incomplete_extraction_never_publishes(self):
        (self.source / "compiler-inputs.ready").write_bytes(b"incomplete\n")
        with self.assertRaises(ValueError):cache.publish(self.root,self.expected,self.source)
        (self.source / "compiler-inputs.ready").write_bytes(b"complete\n")
        (self.source / "dump-streams.tsv").write_bytes(b"1\t100\t100\n")
        with self.assertRaises(ValueError):cache.publish(self.root,self.expected,self.source)

    def footer_proof(self):
        # ET's observed metadata ends with page stream 631 and footer stream 632.
        (self.source / "dump-streams.tsv").write_bytes(b"632\t28802028\t22\n")
        page = b"631\t0\t10\tTemplate:fixture\n"
        (self.source / "page-index.tsv").write_bytes(page)
        header = b"DPTIDX01" + b"".join(n.to_bytes(8, "little") for n in
                                            (2, 8, 1, 1, len(page), 0, 0))
        (self.source / "page-title-index.bin").write_bytes(header + bytes(128))
        proof = dict(schema="wikidict.extraction-completion.v1", version=1,
                     expected_stream_count=633, consumed_stream_count=633, pages=1)
        path = self.source / "extraction-completion.json"
        path.write_text(json.dumps(proof))
        return path, proof

    def test_footer_fullscan_proof_roundtrip_and_asset_tamper(self):
        path, _ = self.footer_proof()
        self.assertEqual(0, cache.publish(self.root, self.expected, self.source))
        generation, = self.root.iterdir()
        marker = cache.read_marker(generation / ".complete.json")
        self.assertIn(path.name, [row[0] for row in marker["assets"]])
        output = self.base / "footer-output"
        output.mkdir()
        self.assertEqual(0, cache.probe(self.root, self.expected, output))
        self.assertFalse((output / path.name).is_symlink())
        self.assertEqual(path.read_bytes(), (output / path.name).read_bytes())
        (generation / path.name).write_text("{}")
        rejected = self.base / "tampered-output"
        rejected.mkdir()
        self.assertEqual(cache.MISS, cache.probe(self.root, self.expected, rejected))
        self.assertEqual([], list(rejected.iterdir()))

    def test_footer_missing_truncated_and_forged_proof_rejected(self):
        path, proof = self.footer_proof()
        variants = [b"{", b" " * 4097, b"[]"]
        for field in proof:
            missing = dict(proof)
            del missing[field]
            variants.append(json.dumps(missing).encode())
        for field, value in (("version", True), ("schema", "other"),
                             ("expected_stream_count", 632), ("consumed_stream_count", 632),
                             ("pages", 2), ("pages", 0), ("pages", True),
                             ("consumed_stream_count", "633"), ("expected_stream_count", -1)):
            variants.append(json.dumps(dict(proof, **{field: value})).encode())
        for raw in variants:
            with self.subTest(raw=raw[:100]):
                path.write_bytes(raw)
                with self.assertRaises(ValueError):
                    cache.validate_extraction_completion(self.source)
        path.unlink()
        with self.assertRaisesRegex(ValueError, "final page stream"):
            cache.validate_extraction_completion(self.source)

    def test_footer_proof_does_not_waive_index_or_ready_guards(self):
        path, proof = self.footer_proof()
        title = self.source / "page-title-index.bin"
        valid_title = title.read_bytes()
        for body in (valid_title[:32], valid_title[:-1], b"BADMAGIC" + valid_title[8:],
                     valid_title[:8] + bytes(8) + valid_title[16:]):
            title.write_bytes(body)
            with self.assertRaises(ValueError):cache.validate_extraction_completion(self.source)
        title.write_bytes(valid_title)
        (self.source / "page-index.tsv").write_bytes(b"634\t0\t10\tTemplate:fixture\n")
        with self.assertRaises(ValueError):cache.validate_extraction_completion(self.source)
        self.footer_proof()
        (self.source / "page-index.tsv").write_bytes(b"631\t0\t10\tLongerTemplate:fixture\n")
        with self.assertRaises(ValueError):cache.validate_extraction_completion(self.source)
        self.footer_proof()
        (self.source / "compiler-inputs.ready").write_bytes(b"incomplete\n")
        with self.assertRaises(ValueError):cache.validate_extraction_completion(self.source)
        (self.source / "compiler-inputs.ready").write_bytes(b"complete\n")
        self.footer_proof()
        target = self.base / "proof-backing"
        path.rename(target)
        path.symlink_to(target)
        with self.assertRaises(ValueError):cache.validate_extraction_completion(self.source)
        with self.assertRaises(ValueError):cache.walk_assets(self.source)
        target.unlink()
        with self.assertRaises(ValueError):cache.validate_extraction_completion(self.source)

    def test_present_invalid_proof_rejected_even_with_equal_tails(self):
        path, _ = self.footer_proof()
        (self.source / "dump-streams.tsv").write_bytes(b"631\t0\t22\n")
        with self.assertRaises(ValueError):cache.validate_extraction_completion(self.source)

    def test_namespace_registry_is_part_of_identity(self):
        with mock.patch.object(cache, "tool_identity", return_value={}):
            original=cache.identity(Path("extractor"), "a"*64, "d"*64, "e"*64)
            changed=cache.identity(Path("extractor"), "a"*64, "d"*64, "f"*64)
        self.assertNotEqual(original,changed)
        self.assertEqual(2,len(original["unicode_case"]["libraries"]))

    def test_extractor_argv_is_part_of_identity(self):
        with mock.patch.object(cache, "tool_identity", return_value=self.expected["tool"]):
            original = cache.identity(Path("extractor"), "a" * 64, "d" * 64, "e" * 64)
            with mock.patch.object(cache, "EXTRACTOR_ARGS", ("--other-mode",)):
                changed = cache.identity(Path("extractor"), "a" * 64, "d" * 64, "e" * 64)
        self.assertEqual(["--page-index"], original["extractor_args"])
        self.assertNotEqual(original, changed)

    def receipt_snapshot(self, root, dump):
        import hashlib,os
        def identity(path, index=False):
            value=path.stat()
            return dict(device_major=os.major(value.st_dev),device_minor=os.minor(value.st_dev),
                        inode=value.st_ino,size=value.st_size,mtime_ns=value.st_mtime_ns,
                        ctime_ns=0 if index else value.st_ctime_ns)
        return dict(version=2,source=identity(dump),indexes=[identity(root/name,True)for name in
                    ('page-index.tsv','page-title-index.bin','dump-streams.tsv')],
                    namespace_sha256=list(hashlib.sha256(b'namespace fixture').digest()),redirects_sha256=None)

    def test_v4_key_isolated_from_actual_historical_probe_and_validated_v3_fallback(self):
        import ast
        # Execute the actual pre-transition probe/validator AST. Its CLI computes
        # v3, so a v4 generation must remain invisible to that ordinary route.
        # Exact three v3 functions retained from canonical fa5d5c19.
        historical = (
            'def identity(executable, dump_sha256, index_sha256, namespace_sha256, transclusion_redirects_sha256=None, page_redirects_sha256=None):\n'
            '    if not all(re.fullmatch(r"[0-9a-fA-F]{64}", value)\n'
            '               for value in (dump_sha256, index_sha256, namespace_sha256)):\n'
            '        raise ValueError("Invalid verified staged input digest")\n'
            '    return {"version": EXTRACTION_IDENTITY_VERSION, "extractor_args": list(EXTRACTOR_ARGS),\n'
            '            "dump_sha256": dump_sha256.lower(),\n'
            '            "index_sha256": index_sha256.lower(),\n'
            '            "namespace_registry_sha256": namespace_sha256.lower(),\n'
            '            "transclusion_redirects_sha256": transclusion_redirects_sha256,\n'
            '            "page_redirects_sha256": page_redirects_sha256,\n'
            '            "unicode_case": unicode_case_identity(),\n'
            '            "tool": tool_identity(executable)}\n'
            '\n'
            'def validate(root, expected):\n'
            '    marker = root / ".complete.json"\n'
            '    record = read_marker(marker)\n'
            '    if not isinstance(record, dict):\n'
            '        return False\n'
            '    if record.get("identity") != expected:\n'
            '        return False\n'
            '    assets = record.get("assets")\n'
            '    if not isinstance(assets, list) or assets != record_assets(root):\n'
            '        return False\n'
            '    validate_extraction_completion(root)\n'
            '    return True\n'
            '\n'
            'def probe(root, expected, output):\n'
            '    key = hashlib.sha256(json.dumps(expected, sort_keys=True).encode()).hexdigest()\n'
            '    source = cache_path(root, key)\n'
            '    if not source.exists():\n'
            '        return MISS\n'
            '    try:\n'
            '        if source.is_symlink() or not validate(source, expected):\n'
            '            return MISS\n'
            '    except (OSError, ValueError, json.JSONDecodeError, TypeError):\n'
            '        return MISS\n'
            '    # Validation is complete before the first link is installed. The cache is\n'
            '    # immutable and the top-level build lock excludes concurrent replacement.\n'
            '    for name in (TREE, *extraction_files(source)):\n'
            '        os.symlink((source / name).resolve(strict=True), output / name,\n'
            '                   target_is_directory=name == TREE)\n'
            '    print(f"Reusing verified extraction assets: {source}", flush=True)\n'
            '    return 0\n'
        )
        tree=ast.parse(historical)
        scope=dict(cache.__dict__,EXTRACTION_IDENTITY_VERSION=3,
                   tool_identity=lambda executable:self.expected['tool'],
                   unicode_case_identity=lambda:self.expected['unicode_case'])
        functions=[node for node in tree.body if isinstance(node,ast.FunctionDef) and node.name in ('probe','validate','identity')]
        self.assertEqual(len(functions),3)
        exec(compile(ast.fix_missing_locations(ast.Module(body=functions,type_ignores=[])),'actual-historical-probe','exec'),scope)
        legacy_identity=scope['identity']('unused','a'*64,'d'*64,'f'*64)
        self.assertEqual(legacy_identity,dict(self.expected,version=3))
        cache.publish(self.root,self.expected,self.source)
        current=next(p for p in self.root.iterdir() if len(p.name)==64)
        old_output=self.base/'historical';old_output.mkdir()
        self.assertEqual(scope['probe'](self.root,legacy_identity,old_output),cache.MISS)
        self.assertEqual(list(old_output.iterdir()),[])
        # Install real legacy-format backing, then remove the unrelated v4 key.
        import shutil
        shutil.rmtree(current)
        cache.publish(self.root,legacy_identity,self.source)
        legacy=next(p for p in self.root.iterdir() if len(p.name)==64)
        marker=legacy/'.complete.json';record=json.loads(marker.read_text());record.pop('asset_ownership',None);marker.write_text(json.dumps(record))
        before={str(p.relative_to(legacy)):(p.read_bytes(),p.stat().st_ino)for p in legacy.rglob('*')if p.is_file()}
        output=self.base/'fallback';output.mkdir()
        self.assertEqual(cache.probe(self.root,self.expected,output),0)
        self.assertEqual((output/'page-index.tsv').stat().st_ino,(legacy/'page-index.tsv').stat().st_ino)
        self.assertFalse((output/'modules').is_symlink())
        cache.publish(self.root,self.expected,output)
        self.assertEqual(before,{str(p.relative_to(legacy)):(p.read_bytes(),p.stat().st_ino)for p in legacy.rglob('*')if p.is_file()})
        # A present corrupt current generation must not silently fall back.
        current=cache.cache_path(self.root,cache.hashlib.sha256(json.dumps(self.expected,sort_keys=True).encode()).hexdigest())
        (current/'.complete.json').write_text('{}')
        rejected=self.base/'rejected';rejected.mkdir()
        self.assertEqual(cache.probe(self.root,self.expected,rejected),cache.MISS)
        self.assertEqual(list(rejected.iterdir()),[])

    def test_legacy_generation_survives_new_publication_without_marker_upgrade(self):
        cache.publish(self.root, self.expected, self.source)
        old = next(p for p in self.root.iterdir() if len(p.name) == 64)
        marker = old / '.complete.json'
        record = json.loads(marker.read_text());record.pop('asset_ownership',None)
        marker.write_text(json.dumps(record))
        before = {str(p.relative_to(old)): (p.read_bytes(), p.stat().st_ino) for p in old.rglob('*') if p.is_file()}
        legacy = self.base / 'legacy';legacy.mkdir()
        for name in (cache.TREE, *cache.extraction_files(old)):
            (legacy / name).symlink_to(old / name, target_is_directory=name == cache.TREE)
        cache.publish(self.root, dict(self.expected, dump_sha256='e'*64), self.source)
        self.assertEqual(before, {str(p.relative_to(old)): (p.read_bytes(), p.stat().st_ino) for p in old.rglob('*') if p.is_file()})
        self.assertEqual((legacy/'modules/123.lua').read_bytes(), b'return 1')
        self.assertTrue(cache.validate(old, self.expected))
        output=self.base/'fresh';output.mkdir()
        self.assertEqual(cache.probe(self.root, self.expected, output), 0)
        cache.publish(self.root, self.expected, self.source)
        self.assertEqual(marker.read_bytes(), before['.complete.json'][0])
        self.assertFalse((output/'manifest.jsonl').is_symlink())

    def test_corrupt_legacy_same_key_is_refused_without_rename_or_replacement(self):
        cache.publish(self.root, self.expected, self.source)
        old=next(p for p in self.root.iterdir() if len(p.name)==64)
        marker=old/'.complete.json';record=json.loads(marker.read_text());record.pop('asset_ownership',None);marker.write_text(json.dumps(record))
        (old/'manifest.jsonl').write_bytes(b'corrupted retained asset')
        before={str(p.relative_to(old)):(p.read_bytes(),p.stat().st_ino) for p in old.rglob('*') if p.is_file()}
        with self.assertRaisesRegex(ValueError, 'unproven legacy'):
            cache.publish(self.root,self.expected,self.source)
        self.assertEqual(before,{str(p.relative_to(old)):(p.read_bytes(),p.stat().st_ino) for p in old.rglob('*') if p.is_file()})
        self.assertEqual([old],list(self.root.iterdir()))
        self.assertEqual(cache.probe(self.root,self.expected,self.base/'unused'),cache.MISS)

    def test_extraction_pruning_keeps_unproven_names_and_stales_but_retires_owned(self):
        import os,time
        cache.publish(self.root,self.expected,self.source)
        old=next(p for p in self.root.iterdir() if len(p.name)==64)
        owned_marker=json.loads((old/'.complete.json').read_text())
        unknown=self.root/('c'*64);unknown.mkdir();(unknown/'.complete.json').write_text('{broken')
        stale=self.root/('.stale-'+'d'*64);stale.mkdir();(stale/'retained').write_bytes(b'legacy')
        part=self.root/'.part-abandoned';part.mkdir()
        for p in (stale,part):os.utime(p,(time.time()-90000,)*2)
        cache.publish(self.root,dict(self.expected,dump_sha256='e'*64),self.source)
        self.assertFalse(old.exists());self.assertTrue(unknown.exists());self.assertEqual((stale/'retained').read_bytes(),b'legacy');self.assertFalse(part.exists())
        self.assertEqual(owned_marker['asset_ownership'],cache.EXTRACTION_OWNERSHIP)
        current=next(p for p in self.root.iterdir() if len(p.name)==64 and p!=unknown)
        (current/'manifest.jsonl').write_bytes(b'bad owned asset')
        conflicting=self.root/('.stale-'+current.name);conflicting.mkdir();(conflicting/'legacy').write_bytes(b'keep')
        with self.assertRaisesRegex(ValueError,'unproven stale'):
            cache.publish(self.root,dict(self.expected,dump_sha256='e'*64),self.source)
        self.assertEqual((conflicting/'legacy').read_bytes(),b'keep')
        self.assertTrue(current.exists())
        # A token alone, malformed inventory, or mismatched key cannot authorize
        # retirement, even if a marker otherwise claims the new protocol.
        current_marker=current/'.complete.json'
        complete=json.loads(current_marker.read_text())
        (unknown/'.complete.json').write_text(json.dumps(complete))
        self.assertFalse(cache.extraction_ownership_proven(unknown))  # key mismatch alone
        for record in ({'asset_ownership':cache.EXTRACTION_OWNERSHIP},
                       dict(complete,assets=[]),
                       dict(complete,assets=[['../escape',1,'a'*64]]),
                       dict(complete,identity={'forged':'key'})):
            current_marker.write_text(json.dumps(record))
            cache.prune_extraction_generations(self.root,unknown)
            self.assertTrue(current.exists())
        current_marker.write_text(json.dumps(complete))


    def test_owned_extraction_survives_generation_pruning_and_ordinary_reuse(self):
        import hashlib,os,shutil
        self.footer_proof();dump=self.base/'dump.xml';dump.write_bytes(b'unchanged indexed dump')
        receipt=self.receipt_snapshot(self.source,dump)
        raw=(json.dumps(receipt,sort_keys=True)+'\n').encode();(self.source/'extraction-source.json').write_bytes(raw)
        self.assertEqual(0,cache.publish(self.root,self.expected,self.source))
        old=cache.cache_path(self.root,hashlib.sha256(json.dumps(self.expected,sort_keys=True).encode()).hexdigest())
        retained=self.base/'retained';retained.mkdir();(retained/'namespace-registry.tsv').write_bytes(b'namespace fixture')
        self.assertEqual(0,cache.probe(self.root,self.expected,retained))
        assets=cache.record_assets(retained)
        owned={name:(retained/name).stat().st_ino for name,_,_ in assets}
        for name in (*cache.extraction_files(retained),cache.TREE):self.assertFalse((retained/name).is_symlink())
        self.assertEqual(receipt,self.receipt_snapshot(retained,dump))
        self.assertEqual(raw,(retained/'extraction-source.json').read_bytes())
        # No synthetic receipt rebind: exact original index inodes/mtime remain.
        for name in ('page-index.tsv','page-title-index.bin','dump-streams.tsv'):
            self.assertEqual((old/name).stat().st_ino,(retained/name).stat().st_ino)
        other=self.base/'other-source';shutil.copytree(self.source,other)
        (other/'extraction-source.json').write_text(json.dumps(self.receipt_snapshot(other,dump)))
        shutil.rmtree(self.source)
        changed=dict(self.expected,tool=dict(extractor_sha256='c'*64,libraries=[]))
        self.assertEqual(0,cache.publish(self.root,changed,other));self.assertFalse(old.exists())
        self.assertEqual(assets,cache.record_assets(retained));cache.validate_extraction_completion(retained)
        self.assertEqual(receipt,self.receipt_snapshot(retained,dump))
        self.assertEqual(raw,(retained/'extraction-source.json').read_bytes())
        self.assertEqual(owned,{name:(retained/name).stat().st_ino for name,_,_ in assets})
        self.assertEqual(b'return 1',(retained/'modules/123.lua').read_bytes())
        # Ordinary atomic generated-file replacement must not write shared cache bytes.
        fresh=self.base/'fresh';fresh.mkdir();self.assertEqual(0,cache.probe(self.root,changed,fresh))
        generation=cache.cache_path(self.root,hashlib.sha256(json.dumps(changed,sort_keys=True).encode()).hexdigest())
        previous=(generation/'lua-usage.tsv').read_bytes()
        replacement=fresh/'lua-usage.part';replacement.write_bytes(b'owned new usage')
        os.replace(replacement,fresh/'lua-usage.tsv');self.assertEqual(previous,(generation/'lua-usage.tsv').read_bytes())
        # The retained old output is still a regular, complete ordinary input.
        self.assertEqual(0,cache.publish(self.root,self.expected,retained))
        final=self.base/'final';final.mkdir();self.assertEqual(0,cache.probe(self.root,self.expected,final))
        self.assertEqual(receipt,self.receipt_snapshot(final,dump))
        self.assertEqual(raw,(final/'extraction-source.json').read_bytes())

    def test_cross_device_or_staging_failure_exposes_no_partial_extraction(self):
        import errno,os
        self.assertEqual(0,cache.publish(self.root,self.expected,self.source))
        original=os.link
        generation=cache.cache_path(self.root,cache.hashlib.sha256(json.dumps(self.expected,sort_keys=True).encode()).hexdigest())
        for phase in ('metadata','module'):
            for failure in (errno.EXDEV,errno.EIO):
                output=self.base/('failure-'+phase+'-'+str(failure));output.mkdir();snapshot=output/'namespace-registry.tsv';snapshot.write_bytes(b'prior snapshot')
                calls=[]
                def link(source,destination,**kwargs):
                    calls.append(str(source))
                    if (phase=='metadata' and len(calls)==3) or (phase=='module' and Path(source).suffix=='.lua'):
                        raise OSError(failure,'injected ownership failure')
                    return original(source,destination,**kwargs)
                with self.subTest(phase=phase,failure=failure),mock.patch.object(cache.os,'link',side_effect=link):
                    if failure==errno.EXDEV:self.assertEqual(cache.MISS,cache.probe(self.root,self.expected,output))
                    else:
                        with self.assertRaises(OSError):cache.probe(self.root,self.expected,output)
                self.assertEqual(['namespace-registry.tsv'],[p.name for p in output.iterdir()])
                self.assertEqual(b'prior snapshot',snapshot.read_bytes())
                self.assertTrue(cache.validate(generation,self.expected))

    def test_commit_failure_rolls_back_owned_output_and_existing_targets_are_not_replaced(self):
        self.assertEqual(0,cache.publish(self.root,self.expected,self.source))
        output=self.base/'commit-failure';output.mkdir();snapshot=output/'namespace-registry.tsv';snapshot.write_bytes(b'prior snapshot')
        original=Path.rename;calls=[]
        def rename(source,destination):
            calls.append(str(destination))
            if len(calls)==3:raise OSError('injected install failure')
            return original(source,destination)
        with mock.patch.object(Path,'rename',rename),self.assertRaises(OSError):cache.probe(self.root,self.expected,output)
        self.assertEqual(['namespace-registry.tsv'],[p.name for p in output.iterdir()])
        self.assertEqual(b'prior snapshot',snapshot.read_bytes())
        prior=output/'manifest.jsonl';prior.write_bytes(b'prior extraction')
        with self.assertRaisesRegex(ValueError,'Refusing to replace'):cache.probe(self.root,self.expected,output)
        self.assertEqual(b'prior extraction',prior.read_bytes())
        self.assertEqual({'namespace-registry.tsv','manifest.jsonl'},{p.name for p in output.iterdir()})

    def test_valid_generation_preserves_unproven_older_extraction_cache(self):
        cache.publish(self.root, self.expected, self.source)
        older = self.root / ("f" * 64)
        older.mkdir()
        (older / ".complete.json").write_text("old")
        self.assertEqual(0, cache.publish(self.root, self.expected, self.source))
        self.assertEqual((older / ".complete.json").read_text(), "old")

    def test_missing_required_asset_rejected(self):
        (self.source / "page-title-index.bin").unlink()
        with self.assertRaises(ValueError):
            cache.publish(self.root, self.expected, self.source)

    def test_oversized_and_wrong_shape_extraction_markers_are_misses(self):
        cache.publish(self.root, self.expected, self.source)
        key = cache.hashlib.sha256(cache.json.dumps(self.expected, sort_keys=True).encode()).hexdigest()
        marker = self.root / key / ".complete.json"
        output = self.base / "output"
        output.mkdir()
        with mock.patch.object(cache, "MAX_MARKER_BYTES", 64):
            marker.write_bytes(b" " * 65)
            self.assertEqual(cache.MISS, cache.probe(self.root, self.expected, output))
        marker.write_text("[]")
        self.assertEqual(cache.MISS, cache.probe(self.root, self.expected, output))
        self.assertFalse((output / "modules").exists())


class CompletedExpanderTests(unittest.TestCase):
    def _trace_seal_digest_reads(self, paths):
        import contextlib
        targets = {Path(path).absolute() for path in paths}
        counts = {'bytes': 0, 'reads': 0, 'opens': 0}
        original_open = Path.open
        class Observed:
            def __init__(self, stream): self.stream = stream
            def __enter__(self): self.stream.__enter__(); return self
            def __exit__(self, *args): return self.stream.__exit__(*args)
            def __getattr__(self, name): return getattr(self.stream, name)
            def read(self, *args):
                value = self.stream.read(*args)
                if value:
                    counts['bytes'] += len(value); counts['reads'] += 1
                return value
        def opened(path, *args, **kwargs):
            stream = original_open(path, *args, **kwargs)
            mode = args[0] if args else kwargs.get('mode', 'r')
            if mode == 'rb' and path.absolute() in targets:
                counts['opens'] += 1
                return Observed(stream)
            return stream
        @contextlib.contextmanager
        def trace():
            with mock.patch.object(Path, 'open', opened): yield counts
        return trace()

    def test_seal_digest_memo_preserves_complete_manifest_and_alias_reads(self):
        original = cache.stable_file_digest
        for alias in ('symlink', 'hardlink'):
            with self.subTest(alias=alias):
                root, dump, snapshots = self.fixture(ready=False)
                source = Path(snapshots['interface-messages.tsv'])
                installed = root / 'interface-messages.tsv'
                if alias == 'hardlink':
                    installed.unlink(); cache.os.link(source, installed)
                def without_memo(path, **kwargs):
                    kwargs.pop('_memo', None)
                    return original(path, **kwargs)
                with self._trace_seal_digest_reads((source, installed)) as baseline:
                    with mock.patch.object(cache, 'stable_file_digest', side_effect=without_memo):
                        self.assertEqual(0, self.call('seal-expander', root, dump, snapshots))
                marker = root / cache.COMPLETED_EXPANDER
                expected = marker.read_bytes(); marker.unlink()
                with self._trace_seal_digest_reads((source, installed)) as candidate:
                    self.assertEqual(0, self.call('seal-expander', root, dump, snapshots))
                self.assertEqual(expected, marker.read_bytes())
                self.assertEqual({'bytes': source.stat().st_size * 3, 'reads': 3, 'opens': 3}, baseline)
                self.assertEqual({'bytes': source.stat().st_size, 'reads': 1, 'opens': 3}, candidate)
                print('SEAL_DIGEST_MEMO_COUNTS ' + json.dumps(dict(alias=alias, baseline=baseline, candidate=candidate), sort_keys=True))
                # A distinct call must hash again; the first transaction is not authority.
                marker.unlink()
                with self._trace_seal_digest_reads((source, installed)) as again:
                    self.assertEqual(0, self.call('seal-expander', root, dump, snapshots))
                self.assertEqual(expected, marker.read_bytes())
                self.assertEqual(candidate, again)

    def test_seal_digest_memo_rehashes_content_ctime_mode_and_inode_changes(self):
        for changed in ('content-restored-mtime', 'mode', 'atomic-same-bytes', 'removed'):
            with self.subTest(changed=changed):
                path = self.base / ('digest-' + changed); path.write_bytes(b'original')
                memo = {}; original = cache.stable_file_digest(path, _memo=memo)
                info = path.stat()
                if changed == 'content-restored-mtime':
                    path.write_bytes(b'modified')
                    cache.os.utime(path, ns=(info.st_atime_ns, info.st_mtime_ns))
                    self.assertNotEqual(info.st_ctime_ns, path.stat().st_ctime_ns)
                    self.assertEqual(info.st_size, path.stat().st_size)
                    self.assertEqual(info.st_mtime_ns, path.stat().st_mtime_ns)
                elif changed == 'mode': path.chmod(0o600 if info.st_mode & 0o777 != 0o600 else 0o644)
                elif changed == 'atomic-same-bytes':
                    other = path.with_suffix('.new'); other.write_bytes(b'original')
                    cache.os.utime(other, ns=(info.st_atime_ns, info.st_mtime_ns))
                    other.replace(path); self.assertNotEqual(info.st_ino, path.stat().st_ino)
                else: path.unlink()
                if changed == 'removed':
                    with self.assertRaises(FileNotFoundError): cache.stable_file_digest(path, _memo=memo)
                    continue
                with self._trace_seal_digest_reads((path,)) as counts:
                    actual = cache.stable_file_digest(path, _memo=memo)
                self.assertEqual(path.stat().st_size, counts['bytes'])
                self.assertEqual(1, counts['reads'])
                if changed == 'content-restored-mtime': self.assertNotEqual(original, actual)
                else: self.assertEqual(original, actual)

    def test_seal_digest_memo_checks_alias_policy_and_retargeted_payload(self):
        first = self.base / 'memo-target-first'; first.write_bytes(b'first')
        second = self.base / 'memo-target-second'; second.write_bytes(b'other')
        link = self.base / 'memo-link'; link.symlink_to(first)
        memo = {}; expected = cache.stable_file_digest(first, _memo=memo)
        with self._trace_seal_digest_reads((first,)) as counts:
            self.assertEqual(expected, cache.stable_file_digest(link, snapshot=True, _memo=memo))
        self.assertEqual({'bytes': 0, 'reads': 0, 'opens': 1}, counts)
        with self.assertRaisesRegex(ValueError, 'Linked expander asset'):
            cache.stable_file_digest(link, _memo=memo)
        link.unlink(); link.symlink_to(second)
        with self._trace_seal_digest_reads((second,)) as counts:
            changed = cache.stable_file_digest(link, snapshot=True, _memo=memo)
        self.assertNotEqual(expected, changed); self.assertEqual(5, counts['bytes'])

    def test_seal_digest_memo_rejects_mutation_during_hits_and_misses(self):
        for cached in (False, True):
            with self.subTest(cached=cached):
                path = self.base / ('during-' + str(cached)); path.write_bytes(b'original')
                memo = {}
                if cached: cache.stable_file_digest(path, _memo=memo)
                actual_fstat = cache.os.fstat; calls = 0
                def changing(fd):
                    nonlocal calls
                    result = actual_fstat(fd); calls += 1
                    if calls == 2:
                        before = path.stat(); path.write_bytes(b'modified')
                        cache.os.utime(path, ns=(before.st_atime_ns, before.st_mtime_ns))
                        return actual_fstat(fd)
                    return result
                with mock.patch.object(cache.os, 'fstat', side_effect=changing):
                    with self.assertRaisesRegex(ValueError, 'changed during reading'):
                        cache.stable_file_digest(path, _memo=memo)
                self.assertEqual({}, memo)
                self.assertEqual(cache.stable_file_digest(path), cache.stable_file_digest(path, _memo=memo))

    def test_seal_digest_memo_final_guards_refuse_transaction_changes(self):
        for changed in ('content-restored-mtime', 'mode', 'atomic-same-bytes', 'retarget-same-inode', 'membership'):
            with self.subTest(changed=changed):
                root, dump, snapshots = self.fixture(ready=False)
                source = Path(snapshots['interface-messages.tsv'])
                installed = root / 'interface-messages.tsv'
                alternative = self.base / ('memo-alternative-' + str(self.sequence))
                if changed == 'retarget-same-inode': cache.os.link(source, alternative)
                original = cache.stable_file_digest; fired = False
                def after_selected(path, **kwargs):
                    nonlocal fired
                    result = original(path, **kwargs)
                    if not fired and Path(path) == source and kwargs.get('_memo') is not None:
                        fired = True; info = source.stat(); raw = source.read_bytes()
                        if changed == 'content-restored-mtime':
                            source.write_bytes(bytes([raw[0] ^ 1]) + raw[1:])
                            cache.os.utime(source, ns=(info.st_atime_ns, info.st_mtime_ns))
                        elif changed == 'mode': source.chmod(0o644 if info.st_mode & 0o777 == 0o600 else 0o600)
                        elif changed == 'atomic-same-bytes':
                            alternative.write_bytes(raw)
                            cache.os.utime(alternative, ns=(info.st_atime_ns, info.st_mtime_ns))
                            alternative.replace(source)
                        elif changed == 'retarget-same-inode':
                            installed.unlink(); installed.symlink_to(alternative)
                        else: (root / 'modules/extra.lua').write_bytes(b'return 2')
                    return result
                with mock.patch.object(cache, 'stable_file_digest', side_effect=after_selected):
                    with self.assertRaises(ValueError): self.call('seal-expander', root, dump, snapshots)
                self.assertTrue(fired)
                self.assertFalse((root / cache.COMPLETED_EXPANDER).exists())
                self.assertEqual(b'building', (root / '.incomplete').read_bytes())
                self.assertEqual(b'linking', (root.parent / '.incomplete').read_bytes())

    def test_native_cache_helper_startup_has_no_site_side_effect(self):
        import os
        import re
        import subprocess
        import sys
        source = Path(cache.__file__).with_name('bundle_build.zig').read_text()
        prefixes = re.findall(r'"python3", "-I", "-S", "-B", helper', source)
        # One new isolated probe call plus two mutually exclusive seal argv branches.
        self.assertEqual(len(prefixes), 6)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            marker = root/'startup-executed'
            (root/'sitecustomize.py').write_text('from pathlib import Path\nPath('+repr(str(marker))+').write_text("unexpected")\n')
            environment = dict(os.environ, PYTHONPATH=str(root))
            flags = [value.strip().strip('"') for value in prefixes[0].split(',')[:-1]]
            result = subprocess.run([sys.executable,*flags[1:],cache.__file__,'invalid-action'],
                cwd=root,env=environment,capture_output=True,text=True)
            self.assertNotEqual(result.returncode,0)
            self.assertIn('usage: extraction_cache.py',result.stderr)
            self.assertFalse(marker.exists())

    def setUp(self):
        ObjectCacheTest.setUp(self)
        self.names = ObjectCacheTest.names
        self.sequence = 0
        self.graph = {name: str(self.base / name) for name in
                      ('extractor', 'llvm', 'runtime', 'leaf', 'main_c', 'zig', 'clang')}
        self.graph['project_root'] = str(self.project)
        for name, path in self.graph.items():
            if name != 'project_root':
                Path(path).write_bytes(name.encode());Path(path).chmod(0o755)
        for name in ('build.zig', 'tools/bundle_build.zig', 'tools/extraction_cache.py'):
            path = self.project / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(name.encode())
        self.library = self.base / 'linked-library';self.library.write_bytes(b'library')
        self.unicode = {'libraries': [{'sha256': 'a' * 64}]}
        # No native subprocesses: these external observations retain real file hashes.
        patcher = mock.patch.object(cache, 'tool_identity', side_effect=lambda path: {
            'extractor_sha256': cache.sha256(path),
            'libraries': [[str(self.library), cache.sha256(self.library)]]})
        patcher.start();self.addCleanup(patcher.stop)
        patcher = mock.patch.object(cache, 'unicode_case_identity', side_effect=lambda: self.unicode)
        patcher.start();self.addCleanup(patcher.stop)

    def fixture(self, *, ready=True, output=None):
        self.sequence += 1
        output = output or self.base / ('output-' + str(self.sequence));root = output / '.bundle-expander'
        (root / 'modules').mkdir(parents=True)
        (root / 'modules/123.lua').write_bytes(b'return 1')
        for name in cache.FILES:(root / name).write_bytes(name.encode())
        (root / 'compiler-inputs.ready').write_bytes(b'complete\n')
        (root / 'dump-streams.tsv').write_bytes(b'0\t0\t100\n')
        (root / 'page-index.tsv').write_bytes(b'0\t0\t10\tTemplate:fixture\n')
        dump = self.base / ('dump-' + str(self.sequence));dump.write_bytes(b'original dump')
        namespace = self.base / ('namespace-' + str(self.sequence));namespace.write_bytes(b'namespace fixture')
        (root / 'namespace-registry.tsv').symlink_to(namespace)
        snapshots = dict.fromkeys(cache.EXPANDER_SNAPSHOTS)
        snapshots['namespace-registry.tsv'] = str(namespace)
        messages = self.base / ('messages-' + str(self.sequence));messages.write_bytes(b'message snapshot')
        snapshots['interface-messages.tsv'] = str(messages)
        (root / 'interface-messages.tsv').symlink_to(messages)
        def identity(path, index=False):
            info = path.stat()
            return dict(device_major=cache.os.major(info.st_dev), device_minor=cache.os.minor(info.st_dev),
                        inode=info.st_ino, size=info.st_size, mtime_ns=info.st_mtime_ns,
                        ctime_ns=0 if index else info.st_ctime_ns)
        receipt = dict(version=2, source=identity(dump), indexes=[identity(root / name, True) for name in
                       ('page-index.tsv','page-title-index.bin','dump-streams.tsv')],
                       namespace_sha256=list(bytes.fromhex(cache.sha256(namespace))), redirects_sha256=None)
        (root / 'extraction-source.json').write_text(json.dumps(receipt))
        llvm = ObjectCacheTest.llvm(self, str(root / 'llvm'))
        Path(self.graph['leaf']).write_bytes((llvm / 'value_leaf.bc').read_bytes())
        cache.probe_objects(self.root, 'clang', self.project, llvm, self.flags)
        ObjectCacheTest.complete_missing(self, llvm)
        cache.publish_objects(self.root, llvm, 'clang', self.flags)
        (llvm / 'module-objects.rsp').write_text(''.join(json.dumps(str(llvm / name))+'\n' for name in ObjectCacheTest.names))
        (llvm / 'program.meta').rename(root / 'lua-program.meta')
        (output / 'compile-plan.tsv').write_bytes((llvm / 'batch-plan.tsv').read_bytes())
        (output / 'module-compile-plan.tsv').write_bytes(b'module plan')
        (root / 'dict-bundle-expander').write_bytes(b'linked worker')
        (root / '.incomplete').write_bytes(b'building')
        (output / '.incomplete').write_bytes(b'linking')
        if ready:
            self.assertEqual(0, self.call('seal-expander', root, dump, snapshots))
            cache.shutil.rmtree(llvm)
            (root / '.incomplete').unlink();(output / '.incomplete').write_bytes(b'expander ready')
        return root, dump, snapshots

    def call(self, action, root, dump, snapshots, **kwargs):
        return cache.main(['extraction_cache.py', action, str(root), str(dump),
                          kwargs.get('dump_sha','a'*64), kwargs.get('index_sha','b'*64),
                          json.dumps(self.graph), json.dumps(snapshots)])

    def test_writer_figure_transition_preserves_worker_and_failed_epoch(self):
        import build_wiktionaries as builder
        import copy
        import sys
        from types import SimpleNamespace
        patcher = mock.patch.dict(sys.modules, {'extraction_cache': cache})
        patcher.start(); self.addCleanup(patcher.stop)
        for changed in (None, 'provider', 'namespace', 'xml', 'other-tool', 'seal', 'accepted', 'state-part', 'interrupted', 'foreign-closure', 'accepted-raw', 'state-symlink', 'staged-inode', 'staged-completion', 'raw-root'):
            with self.subTest(changed=changed):
                output = self.base / ('writer-output-' + str(self.sequence))
                workspace = output / 'testwiktionary' / '20261001.shards'
                root, dump, snapshots = self.fixture(ready=False, output=workspace / 'expander')
                staged = workspace / 'input'; staged.mkdir()
                dump = dump.rename(staged / 'pages.xml.zst')
                receipt = json.loads((root / 'extraction-source.json').read_text())
                receipt['source']['ctime_ns'] = dump.stat().st_ctime_ns
                (root / 'extraction-source.json').write_text(json.dumps(receipt))
                hashes = {}
                for name in builder.WRITER_FIGURE_ROLES:
                    filename = builder.auxiliary_snapshot_filename(name)
                    path = root / filename
                    path.write_bytes(('original ' + name).encode())
                    snapshots[filename] = str(path)
                    hashes[name] = cache.sha256(path)
                self.assertEqual(0, self.call('seal-expander', root, dump, snapshots))
                digest = self.binding(root)
                cache.shutil.rmtree(root / 'llvm')
                (root / '.incomplete').unlink(); (root.parent / '.incomplete').write_bytes(b'expander ready')
                seal_bytes = (root / cache.COMPLETED_EXPANDER).read_bytes()
                def reference(path):
                    return dict(path=str(path), bytes=path.stat().st_size, sha256=cache.sha256(path))
                roles = {'dict-blob-build': {'artifact': 'original Writer'}, 'dict-bundle-build': {'artifact': 'original worker driver'}}
                old_identity = dict(source='a'*64, files=['original XML'], native_tool_roles=roles,
                    auxiliary_snapshot_sha256=hashes, auxiliary_capture_sha256=dict.fromkeys(hashes, 'b'*64),
                    auxiliary_capture_artifact_sha256=dict.fromkeys(hashes, 'c'*64))
                raw = self.base / ('writer-raw-' + str(self.sequence)) / 'testwiktionary' / '20261001.raw-shards'
                builder.external_raw_shards(workspace, raw, create=True)
                old = dict(version=3, edition='testwiktionary', date='20261001', files=['original XML'], source='a'*64,
                    production_source='d'*64, now_unix=123, registry_sha256='e'*64,
                    raw_shards_path=str(raw),
                    auxiliary_snapshot_sha256=hashes, auxiliary_capture_sha256=dict.fromkeys(hashes, 'b'*64),
                    auxiliary_capture_artifact_sha256=dict.fromkeys(hashes, 'c'*64),
                    native_generation=dict(seal_sha256=digest, dump=str(dump), build_inputs=old_identity))
                state_path = workspace / 'state.json'; state_path.write_text(json.dumps(old))
                original = self.base / ('writer-state-' + str(self.sequence)); original.write_bytes(state_path.read_bytes())
                identity = copy.deepcopy(old_identity); identity['source']='f'*64
                identity['native_tool_roles']['dict-blob-build']['artifact']='qualified observation Writer'
                for name in builder.WRITER_OBSERVATION_ROLES:identity['auxiliary_snapshot_sha256'][name]='1'*64
                for field in ('auxiliary_capture_sha256', 'auxiliary_capture_artifact_sha256'):
                    identity[field] = dict.fromkeys(hashes, '2'*64)
                current = {k:copy.deepcopy(v) for k,v in old.items() if k not in ('now_unix', 'native_generation')}
                current.update(source='f'*64, production_source='3'*64)
                for field in ('auxiliary_snapshot_sha256', 'auxiliary_capture_sha256', 'auxiliary_capture_artifact_sha256'):
                    current[field]=copy.deepcopy(identity[field])
                if changed in ('provider', 'namespace'):
                    if changed=='provider':
                        identity['auxiliary_snapshot_sha256']['file-metadata']='4'*64
                        current['auxiliary_snapshot_sha256']['file-metadata']='4'*64
                    else:current['registry_sha256']='4'*64
                if changed=='xml':identity['files']=['different XML']
                if changed=='other-tool':identity['native_tool_roles']['dict-bundle-build']['artifact']='different driver'
                configuration=self.base/('writer-configuration-'+str(self.sequence))
                def directory(path):
                    info=path.stat()
                    return dict(path=str(path),device=info.st_dev,inode=info.st_ino,uid=info.st_uid,mode=info.st_mode & 0o7777)
                (staged/'.complete.json').write_text(json.dumps(dict(version=1,source_pages=1)))
                staged_record=dict(directory(staged),completion=reference(staged/'.complete.json'))
                execution=dict(output=directory(output),raw=directory(raw.parent.parent))
                if changed=='staged-inode':staged_record['inode']+=1
                if changed=='raw-root':execution['raw']['inode']+=1
                configuration.write_text(json.dumps(dict(date=old['date'],source=dict(fingerprint=old['source']),
                    output=str(output),raw_shard_root=str(raw.parent.parent),execution_root=execution,retained_native_roles=roles,
                    edition_options=dict(testwiktionary=dict(staged_input_root=staged_record,
                        auxiliary_snapshots={name:dict(sha256=value) for name,value in hashes.items()})))))
                result=self.base/('writer-result-'+str(self.sequence))
                result.write_text(json.dumps(dict(production_started=True,outcome='failed',exit_code=1,edition=old['edition'])))
                result_ref=reference(result)
                closure=self.base/('writer-closure-'+str(self.sequence))
                closure.write_text(json.dumps(dict(physical_closure=True,cleanup_complete=True,source_guard_after=True,
                    configuration=reference(configuration),execution_root=execution,attempts=[result_ref],
                    attempt_evidence={str(result):dict(result=result_ref,physical_closure=True,source_guard_after=True)})))
                shards=workspace/'shards'; shards.mkdir(); (shards/'failed-record').write_bytes(b'preserved failed bytes')
                if changed=='accepted':(shards/'.verified').write_bytes(b'verified')
                if changed=='accepted-raw':
                    accepted=raw/'00000000';accepted.mkdir();(accepted/'complete.json').write_text('{}')
                if changed=='state-part':state_path.with_suffix('.part').write_bytes(b'foreign transaction')
                proof=dict(workspace=str(workspace),dump=str(dump),original_state=reference(original),original_closure=reference(closure),
                    original_configuration=reference(configuration),original_result=result_ref,
                    current_state=current,current_build_identity=identity,seal=reference(root/cache.COMPLETED_EXPANDER),retired_paths=[str(shards)])
                if changed=='foreign-closure':
                    value=json.loads(closure.read_text());value['attempts']=[];closure.write_text(json.dumps(value))
                    proof['original_closure']=reference(closure)
                selected=self.base/('writer-proof-'+str(self.sequence)); selected.write_text(json.dumps(proof)); selected_ref=reference(selected)
                native=SimpleNamespace(require_unchanged=lambda:None,provenance=lambda:identity['native_tool_roles'])
                if changed=='seal':(root/cache.COMPLETED_EXPANDER).write_bytes(seal_bytes+b' ')
                if changed=='staged-completion':(staged/'.complete.json').write_text('{}')
                if changed=='state-symlink':
                    state_path.unlink(); state_path.symlink_to(original)
                args=(workspace,current,123,identity,dump,selected_ref,native)
                if changed in ('provider','namespace','xml','other-tool','seal','accepted','state-part','foreign-closure','accepted-raw','state-symlink','staged-inode','staged-completion','raw-root'):
                    with self.assertRaises(ValueError):builder.writer_figure_adopt_workspace(*args)
                    self.assertEqual(old,json.loads(state_path.read_text()))
                    self.assertEqual(b'preserved failed bytes',(shards/'failed-record').read_bytes())
                    if changed=='state-symlink':
                        self.assertTrue(state_path.is_symlink())
                        self.assertEqual(old,json.loads(original.read_text()))
                        self.assertFalse(workspace.with_name(workspace.name+'.writer-figure-'+reference(original)['sha256'][:16]).exists())
                    continue
                if changed=='interrupted':
                    original_replace=builder.os.replace
                    def interrupt(source,destination):
                        if destination==state_path:raise OSError('injected state publication failure')
                        return original_replace(source,destination)
                    with mock.patch.object(builder.os,'replace',side_effect=interrupt):
                        with self.assertRaisesRegex(OSError,'injected'):builder.writer_figure_adopt_workspace(*args)
                    self.assertEqual(old,json.loads(state_path.read_text()))
                    self.assertFalse(shards.exists())
                self.assertEqual(123,builder.writer_figure_adopt_workspace(*args))
                adopted=json.loads(state_path.read_text())
                self.assertEqual(old['native_generation']['build_inputs'],adopted['native_generation']['build_inputs'])
                self.assertEqual(seal_bytes,(root/cache.COMPLETED_EXPANDER).read_bytes())
                self.assertIsNotNone(cache.frozen_runtime_context(root,dump,digest))
                archive=workspace.with_name(workspace.name+'.writer-figure-'+reference(original)['sha256'][:16])
                self.assertEqual(b'preserved failed bytes',(archive/'0'/'failed-record').read_bytes())
                # Later ordinary blob failure does not require changing the selected transition.
                self.assertEqual(123,builder.writer_figure_adopt_workspace(*args))
                self.assertEqual(adopted,json.loads(state_path.read_text()))

    def test_seal_optional_book_snapshot_absence_and_presence(self):
        root, dump, snapshots = self.fixture(ready=False)
        self.assertIn('figure-page-observations.json', snapshots)
        self.assertIsNone(snapshots['figure-page-observations.json'])
        self.assertEqual(0, self.call('seal-expander', root, dump, snapshots))
        root2, dump2, snapshots2 = self.fixture(ready=False)
        book = self.base / 'book-observations.json'
        book.write_bytes(b'qualified observations')
        snapshots2['figure-page-observations.json'] = str(book)
        (root2 / 'figure-page-observations.json').symlink_to(book)
        self.assertEqual(0, self.call('seal-expander', root2, dump2, snapshots2))
        binding = self.binding(root2)
        cache.shutil.rmtree(root2 / 'llvm')
        (root2 / '.incomplete').unlink()
        (root2.parent / '.incomplete').write_bytes(b'expander ready')
        self.assertIsNotNone(cache.frozen_runtime_context(root2, dump2, binding))
        book.write_bytes(b'changed observations')
        with self.assertRaises(ValueError):
            cache.frozen_runtime_context(root2, dump2, binding)

    def test_seal_snapshot_inventory_refuses_missing_and_unknown_roles(self):
        root, dump, snapshots = self.fixture(ready=False)
        for changed in ({k:v for k,v in snapshots.items() if k != 'figure-page-observations.json'},
                        dict(snapshots, unknown=None)):
            with self.assertRaisesRegex(ValueError, 'Invalid completed expander inputs'):
                self.call('seal-expander', root, dump, changed)
        self.assertFalse((root / cache.COMPLETED_EXPANDER).exists())

    def test_sealed_recovery_finalizes_without_compilation(self):
        root, dump, snapshots = self.fixture(ready=False)
        self.call('seal-expander', root, dump, snapshots)
        binding = self.binding(root)
        original = cache.read_marker(root / cache.COMPLETED_EXPANDER)
        self.assertIsNone(cache.frozen_runtime_context(root, dump, binding))
        self.assertEqual(original, cache.finalize_sealed_expander(root, dump, binding, self.graph))
        self.assertFalse((root / 'llvm').exists())
        self.assertFalse((root / '.incomplete').exists())
        self.assertEqual(b'expander ready', (root.parent / '.incomplete').read_bytes())
        self.assertEqual(original, cache.frozen_runtime_context(root, dump, binding))
        self.assertEqual(original, cache.finalize_sealed_expander(root, dump, binding, self.graph))

    def test_relative_sealed_recovery_uses_bound_root_without_changing_original_graph(self):
        import contextlib
        root, dump, snapshots = self.fixture(ready=False)
        graph = dict(self.graph, project_root='.')
        with contextlib.chdir(self.project):
            cache.seal_completed_expander(root, dump, 'a'*64, 'b'*64, graph, snapshots)
        binding = self.binding(root)
        original_bytes = (root / cache.COMPLETED_EXPANDER).read_bytes()
        original = json.loads(original_bytes)
        helper = self.project / 'tools/extraction_cache.py'
        saved_helper = self.base / 'original-relative-helper.py'
        saved_helper.write_bytes(helper.read_bytes())
        helper.write_bytes(b'new maintained finalizer policy')
        def reference(path):
            return dict(path=str(path), bytes=path.stat().st_size, sha256=cache.sha256(path))
        transition = dict(original=reference(saved_helper), current=reference(helper))
        unrelated = self.base / 'unrelated-cwd';unrelated.mkdir()
        with contextlib.chdir(unrelated):
            for invalid_root in (None, Path('.'), unrelated, self.base / 'missing-source'):
                with self.subTest(project_root=invalid_root), self.assertRaises(ValueError):
                    cache.finalize_sealed_expander(root, dump, binding, graph,
                        project_root=invalid_root, helper_transition=transition)
                self.assertTrue((root / 'llvm').exists())
                self.assertEqual(original_bytes, (root / cache.COMPLETED_EXPANDER).read_bytes())
            abi = self.project / cache.ABI_FILES[0]
            abi_bytes = abi.read_bytes()
            try:
                abi.write_bytes(b'drifted ABI in the bound source root')
                with self.assertRaises(ValueError):
                    cache.finalize_sealed_expander(root, dump, binding, graph,
                        project_root=self.project, helper_transition=transition)
                self.assertTrue((root / 'llvm').exists())
            finally:
                abi.write_bytes(abi_bytes)
            self.assertEqual(original, cache.finalize_sealed_expander(root, dump, binding, graph,
                project_root=self.project, helper_transition=transition))
            self.assertEqual(unrelated, Path.cwd())
            self.assertEqual(original, cache.finalize_sealed_expander(root, dump, binding, graph,
                project_root=self.project, helper_transition=transition))
        self.assertEqual(original_bytes, (root / cache.COMPLETED_EXPANDER).read_bytes())
        self.assertEqual('.', original['origin_graph']['project_root'])
        self.assertIsNotNone(cache.frozen_runtime_context(root, dump, binding))

    def test_sealed_recovery_explicit_helper_transition_preserves_original_producer(self):
        root, dump, snapshots = self.fixture(ready=False)
        self.call('seal-expander', root, dump, snapshots)
        binding = self.binding(root)
        before = cache.read_marker(root / cache.COMPLETED_EXPANDER)
        helper = self.project / 'tools/extraction_cache.py'
        old = self.base / 'original-cache-helper.py'
        old.write_bytes(helper.read_bytes())
        helper.write_bytes(b'new maintained finalizer policy')
        def reference(path):
            return dict(path=str(path), bytes=path.stat().st_size, sha256=cache.sha256(path))
        transition = dict(original=reference(old), current=reference(helper))
        with self.assertRaises(ValueError):
            cache.finalize_sealed_expander(root, dump, binding, self.graph)
        self.assertTrue((root / 'llvm').exists())
        after = cache.finalize_sealed_expander(root, dump, binding, self.graph, helper_transition=transition)
        self.assertEqual(before, after)
        self.assertEqual(binding, self.binding(root))
        self.assertEqual(before['identity']['producer'], after['identity']['producer'])

    def test_sealed_recovery_interrupted_ready_and_cleanup_are_resumable(self):
        for boundary in ('parent-ready', 'child-marker', 'scratch-cleanup'):
            with self.subTest(boundary=boundary):
                root, dump, snapshots = self.fixture(ready=False)
                self.call('seal-expander', root, dump, snapshots)
                binding = self.binding(root)
                original_write = Path.write_bytes
                original_unlink = Path.unlink
                def write(path, raw):
                    if path == root.parent / '.incomplete':raise OSError('injected parent ready failure')
                    return original_write(path, raw)
                def unlink(path, *args, **kwargs):
                    if path == root / '.incomplete':raise OSError('injected child marker failure')
                    return original_unlink(path, *args, **kwargs)
                def partial_cleanup(path):
                    (Path(path) / ObjectCacheTest.names[0]).unlink()
                    raise OSError('injected failure after one scratch leaf retired')
                selected = (mock.patch.object(Path, 'write_bytes', write) if boundary == 'parent-ready' else
                            mock.patch.object(Path, 'unlink', unlink) if boundary == 'child-marker' else
                            mock.patch.object(cache.shutil, 'rmtree', side_effect=partial_cleanup))
                with selected, self.assertRaises(OSError):
                    cache.finalize_sealed_expander(root, dump, binding, self.graph)
                self.assertEqual(binding, self.binding(root))
                self.assertIsNotNone(cache.finalize_sealed_expander(root, dump, binding, self.graph))
                self.assertIsNotNone(cache.frozen_runtime_context(root, dump, binding))

    def test_sealed_recovery_rejects_input_tool_abi_seal_and_object_drift(self):
        for changed in ('dump', 'tool', 'abi', 'seal', 'object'):
            with self.subTest(changed=changed):
                root, dump, snapshots = self.fixture(ready=False)
                self.call('seal-expander', root, dump, snapshots)
                binding = self.binding(root)
                if changed == 'dump':dump.write_bytes(b'changed dump')
                elif changed == 'tool':Path(self.graph['runtime']).write_bytes(b'changed runtime')
                elif changed == 'abi':(self.project / cache.ABI_FILES[0]).write_bytes(b'changed ABI')
                elif changed == 'seal':(root / cache.COMPLETED_EXPANDER).write_bytes(b'{}')
                else:(root / 'llvm' / ObjectCacheTest.names[0]).write_bytes(b'changed object')
                with self.assertRaises((ValueError, FileNotFoundError)):
                    cache.finalize_sealed_expander(root, dump, binding, self.graph)
                self.assertTrue((root / 'llvm').exists())
                self.assertEqual(b'building', (root / '.incomplete').read_bytes())

    def test_preblob_workspace_recovery_keeps_original_origin_and_refuses_partial_output(self):
        import build_wiktionaries as builder
        from types import SimpleNamespace
        import sys
        patcher = mock.patch.dict(sys.modules, {'extraction_cache': cache})
        patcher.start();self.addCleanup(patcher.stop)
        for changed in (None, 'input', 'source', 'tool', 'partial', 'state-part', 'state-replace', 'state-open-conflict', 'outer-partial', 'raw-owner', 'raw-payload', 'raw-marker-invalid', 'raw-marker-malformed', 'relative-origin', 'relative-origin-no-root'):
            with self.subTest(changed=changed):
                workspace = self.base / ('workspace-' + str(self.sequence))
                root, dump, snapshots = self.fixture(ready=False, output=workspace / 'expander')
                graph = dict(self.graph)
                if changed in ('relative-origin', 'relative-origin-no-root'):
                    import contextlib
                    graph['project_root'] = '.'
                    with contextlib.chdir(self.project):
                        cache.seal_completed_expander(root, dump, 'a'*64, 'b'*64, graph, snapshots)
                else:
                    self.call('seal-expander', root, dump, snapshots)
                binding = self.binding(root)
                old = dict(version=3, edition='testwiktionary', date='20261001', files=[],
                           source='a'*64, production_source='b'*64, now_unix=123)
                if changed in ('raw-owner', 'raw-payload', 'raw-marker-invalid', 'raw-marker-malformed'):
                    raw = self.base / ('raw-' + str(self.sequence))
                    builder.external_raw_shards(workspace, raw, create=True)
                    old['raw_shards_path'] = str(raw)
                (workspace / 'state.json').write_text(json.dumps(old))
                original = self.base / ('original-state-' + str(self.sequence) + '.json')
                original.write_text(json.dumps(old))
                current = dict(old, source='c'*64, production_source='d'*64)
                del current['now_unix']
                roles = {'writer': {'artifact': 'actual qualified artifact', 'dependencies': {}}}
                if changed == 'relative-origin':
                    roles['dict-bundle-build'] = dict(source_root=str(self.project), dependencies={})
                old_identity = dict(source=old['source'], files=[], native_tool_roles=roles)
                identity = dict(old_identity, source=current['source'])
                def reference(path):
                    return dict(path=str(path), bytes=path.stat().st_size, sha256=cache.sha256(path))
                closure = self.base / ('closure-' + str(self.sequence) + '.json')
                closure.write_text(json.dumps(dict(physical_closure=True, cleanup_complete=True, source_guard_after=True)))
                proof = dict(workspace=str(workspace), original_state=reference(original),
                             original_closure=reference(closure),
                             current_state=current, current_build_identity=identity,
                             original_build_identity=old_identity, dump=str(dump),
                             seal=reference(root / cache.COMPLETED_EXPANDER), origin_graph=graph)
                selected = self.base / ('recovery-' + str(self.sequence) + '.json')
                selected.write_text(json.dumps(proof))
                selected_ref = reference(selected)
                native = SimpleNamespace(require_unchanged=lambda: None, provenance=lambda: roles)
                if changed == 'outer-partial':
                    import ast, inspect, textwrap
                    body = ast.parse(textwrap.dedent(inspect.getsource(builder._build_locked))).body[0].body
                    index = next(i for i, node in enumerate(body) if isinstance(node, ast.Assign)
                                 and any(isinstance(target, ast.Name) and target.id == 'target' for target in node.targets))
                    # Exercise the production preflight through the sealed recovery guard.
                    end = next(i for i, node in enumerate(body[index + 1:], index + 1)
                               if isinstance(node, ast.If) and any(isinstance(part, ast.Attribute)
                               and part.attr == 'sealed_expander_recovery' for part in ast.walk(node.test)))
                    output = self.base / 'outer-output'
                    staging = output / current['edition'] / (current['date'] + '.building')
                    staging.mkdir(parents=True)
                    payload = staging / 'partial-blob';payload.write_bytes(b'unique partial output')
                    namespace = dict(builder.__dict__, output=output, edition=current['edition'], date=current['date'],
                                     retained_roles=SimpleNamespace(sealed_expander_recovery=selected_ref), build_identity=identity)
                    block = ast.fix_missing_locations(ast.Module(body=body[index:end + 1], type_ignores=[]))
                    with self.assertRaisesRegex(ValueError, 'existing partial or published output'):
                        exec(compile(block, '<actual outer recovery guard>', 'exec'), namespace)
                    self.assertEqual(b'unique partial output', payload.read_bytes())
                    self.assertTrue((root / 'llvm').exists())
                    continue
                if changed == 'input':current = dict(current, files=['changed'])
                elif changed == 'source':current = dict(current, source='f'*64)
                elif changed == 'tool':identity = dict(identity, native_tool_roles={})
                elif changed == 'partial':(workspace / 'shards').mkdir()
                elif changed == 'state-part':(workspace / 'state.part').write_bytes(b'unknown transaction')
                elif changed == 'raw-payload':(raw / 'unexpected-payload').write_bytes(b'partial blob')
                elif changed == 'raw-marker-invalid':(raw / builder.RAW_SHARD_OWNER).write_text(json.dumps(dict(version=1, workspace='another workspace', raw_shards=str(raw))))
                elif changed == 'raw-marker-malformed':(raw / builder.RAW_SHARD_OWNER).write_bytes(b'not JSON')
                raw_marker_before = (raw / builder.RAW_SHARD_OWNER).read_bytes() if isinstance(changed,str) and changed.startswith('raw-') else None
                before = (workspace / 'state.json').read_bytes()
                if changed == 'state-open-conflict':
                    original_open = Path.open
                    temporary = workspace / 'state.part'
                    def conflict(path, *args, **kwargs):
                        if path == temporary and args and args[0] == 'x':
                            with original_open(path, 'x') as other:other.write('other transaction')
                            raise FileExistsError('injected exclusive-open conflict')
                        return original_open(path, *args, **kwargs)
                    with mock.patch.object(Path, 'open', conflict), self.assertRaises(FileExistsError):
                        builder.prepare_shard_workspace(workspace, {k:v for k,v in current.items() if k != 'raw_shards_path'}, 123, raw_shards_path=current.get('raw_shards_path'), sealed_recovery=selected_ref,
                                                        native_roles=native, build_identity=identity, dump=dump)
                    self.assertEqual('other transaction', temporary.read_text())
                    self.assertEqual(before, (workspace / 'state.json').read_bytes())
                elif changed == 'state-replace':
                    with mock.patch.object(builder.os, 'replace', side_effect=OSError('injected state publication failure')), self.assertRaises(OSError):
                        builder.prepare_shard_workspace(workspace, {k:v for k,v in current.items() if k != 'raw_shards_path'}, 123, raw_shards_path=current.get('raw_shards_path'), sealed_recovery=selected_ref,
                                                        native_roles=native, build_identity=identity, dump=dump)
                    self.assertEqual(before, (workspace / 'state.json').read_bytes())
                    self.assertFalse((workspace / 'state.part').exists())
                    self.assertEqual(123, builder.prepare_shard_workspace(workspace, {k:v for k,v in current.items() if k != 'raw_shards_path'}, 123, raw_shards_path=current.get('raw_shards_path'),
                        sealed_recovery=selected_ref, native_roles=native, build_identity=identity, dump=dump))
                elif changed and changed not in ('raw-owner', 'relative-origin'):
                    with self.assertRaises(ValueError):
                        builder.prepare_shard_workspace(workspace, {k:v for k,v in current.items() if k != 'raw_shards_path'}, 123, raw_shards_path=current.get('raw_shards_path'), sealed_recovery=selected_ref,
                                                        native_roles=native, build_identity=identity, dump=dump)
                    self.assertEqual(before, (workspace / 'state.json').read_bytes())
                    self.assertTrue((root / 'llvm').exists())
                    if raw_marker_before is not None:self.assertEqual(raw_marker_before, (raw / builder.RAW_SHARD_OWNER).read_bytes())
                    if changed == 'raw-payload':self.assertEqual(b'partial blob', (raw / 'unexpected-payload').read_bytes())
                else:
                    self.assertEqual(123, builder.prepare_shard_workspace(workspace, {k:v for k,v in current.items() if k != 'raw_shards_path'}, 123, raw_shards_path=current.get('raw_shards_path'),
                        sealed_recovery=selected_ref, native_roles=native, build_identity=identity, dump=dump))
                    self.assertEqual(123, builder.prepare_shard_workspace(workspace, {k:v for k,v in current.items() if k != 'raw_shards_path'}, 123, raw_shards_path=current.get('raw_shards_path'),
                        sealed_recovery=selected_ref, native_roles=native, build_identity=identity, dump=dump))
                    with self.assertRaisesRegex(ValueError, 'Adopted sealed recovery identity changed'):
                        builder.prepare_shard_workspace(workspace, {k:v for k,v in current.items() if k != 'raw_shards_path'}, 123, raw_shards_path=current.get('raw_shards_path'),
                            sealed_recovery=selected_ref, native_roles=native,
                            build_identity=dict(identity, native_tool_roles={}), dump=dump)
                    after = json.loads((workspace / 'state.json').read_text())
                    self.assertEqual(binding, after['native_generation']['seal_sha256'])
                    self.assertEqual(identity, after['native_generation']['build_inputs'])
                    self.assertEqual(old, json.loads(original.read_text()))
                    if changed == 'raw-owner':self.assertEqual(raw_marker_before, (raw / builder.RAW_SHARD_OWNER).read_bytes())
                    self.assertEqual(graph, cache.read_marker(root / cache.COMPLETED_EXPANDER)['origin_graph'])

    def binding(self, root):
        return cache.sha256(root / cache.COMPLETED_EXPANDER)

    def provider_update_fixture(self):
        root,dump,snapshots=self.fixture(ready=False)
        for name in cache.WIKIBASE_PROVIDER_FILES:
            source=self.base/(str(self.sequence)+'-'+name)
            source.write_text(json.dumps({'Q1': 'original', 'role': name})+'\n')
            snapshots[name]=str(source);(root/name).symlink_to(source)
        self.call('seal-expander',root,dump,snapshots)
        cache.shutil.rmtree(root/'llvm')
        (root/'.incomplete').unlink();(root.parent/'.incomplete').write_bytes(b'expander ready')
        return root,dump,snapshots

    def stage_provider_update(self,root,snapshots,value):
        (root/'.incomplete').write_bytes(cache.PROVIDER_UPDATE_MARKER)
        for name in cache.WIKIBASE_PROVIDER_FILES:
            source=Path(snapshots[name]);temporary=source.with_suffix('.part')
            temporary.write_text(json.dumps({'Q1': 'original', 'Q2':value, 'role':name})+'\n')
            cache.os.replace(temporary,source)
        return {name:cache.sha256(root/name) for name in cache.WIKIBASE_PROVIDER_FILES}

    def test_provider_update_keeps_native_bytes_inode_and_original_compilation_origin(self):
        root,dump,snapshots=self.provider_update_fixture();original=self.binding(root)
        before=cache.read_marker(root/cache.COMPLETED_EXPANDER)
        assets={name:((root/name).read_bytes(),cache._full_stamp((root/name).stat()))
                for name in ('dict-bundle-expander','lua-program.meta','modules/123.lua')}
        proof=cache.prepare_wikibase_provider_update(root,dump,original)
        hashes=self.stage_provider_update(root,snapshots,'captured new value')
        successor=cache.finish_wikibase_provider_update(proof,hashes)
        self.assertIsNone(cache.frozen_runtime_context(root,dump,successor))
        self.assertEqual('ordinary-wikibase-provider-update',
            cache.frozen_runtime_context(root,dump,successor,provider_update=True)['provenance'])
        (root/'.incomplete').unlink()
        after=cache.frozen_runtime_context(root,dump,successor)
        self.assertEqual('ordinary-wikibase-provider-update',after['provenance'])
        self.assertEqual(original,after['provider_update']['original_seal_sha256'])
        for key in ('origin_graph','link'):
            self.assertEqual(before[key],after[key])
        for key in ('producer','source','verified_input','runtime_libraries','plans'):
            self.assertEqual(before['identity'][key],after['identity'][key])
        for name,(raw,stamp) in assets.items():
            self.assertEqual(raw,(root/name).read_bytes());self.assertEqual(stamp,cache._full_stamp((root/name).stat()))
        for name in cache.WIKIBASE_PROVIDER_FILES:
            self.assertEqual('captured new value',json.loads((root/name).read_text())['Q2'])
            self.assertEqual(hashes[name],after['identity']['providers'][name][1])
        with self.assertRaises(ValueError):cache.frozen_runtime_context(root,dump,original)

    def test_provider_update_preserves_legacy_snapshot_inventory(self):
        root, dump, snapshots = self.provider_update_fixture()
        marker = root / cache.COMPLETED_EXPANDER
        record = cache.read_marker(marker)
        del record['identity']['providers']['figure-page-observations.json']
        cache.write_private_marker(marker, record)
        original = self.binding(root)
        proof = cache.prepare_wikibase_provider_update(root, dump, original)
        self.assertIsNotNone(proof)
        hashes = self.stage_provider_update(root, snapshots, 'legacy successor')
        successor = cache.finish_wikibase_provider_update(proof, hashes)
        after = cache.frozen_runtime_context(root, dump, successor, provider_update=True)
        self.assertEqual(set(record['identity']['providers']), set(after['identity']['providers']))
        self.assertEqual(record['origin_graph'], after['origin_graph'])
        self.assertEqual(record['link'], after['link'])
        self.assertEqual(record['identity']['producer'], after['identity']['producer'])
        self.assertNotIn('figure-page-observations.json', after['identity']['providers'])


    def test_legacy_nonprovider_newly_named_asset_remains_native_immutable(self):
        for changed in (False, True):
            with self.subTest(changed=changed):
                root, dump, snapshots = self.provider_update_fixture()
                marker = root / cache.COMPLETED_EXPANDER
                book = root / 'figure-page-observations.json'
                book.write_bytes(b'original native asset under legacy inventory')
                record = cache.read_marker(marker)
                del record['identity']['providers'][book.name]
                record['identity']['assets'].append([book.name, *cache.stable_file_digest(book)])
                record['runtime_stamps']['assets'][book.name] = list(cache._full_stamp(book.stat()))
                record['runtime_stamps']['snapshot_links'][book.name] = None
                cache.write_private_marker(marker, record)
                proof = cache.prepare_wikibase_provider_update(root, dump, self.binding(root))
                self.assertIsNotNone(proof)
                hashes = self.stage_provider_update(root, snapshots, 'legacy native asset')
                before = marker.read_bytes()
                if changed:
                    book.write_bytes(b'changed native asset')
                    with self.assertRaisesRegex(ValueError, 'changed native asset'):
                        cache.finish_wikibase_provider_update(proof, hashes)
                    self.assertEqual(before, marker.read_bytes())
                else:
                    successor = cache.finish_wikibase_provider_update(proof, hashes)
                    self.assertIsNotNone(cache.frozen_runtime_context(root, dump, successor, provider_update=True))
                    self.assertNotIn(book.name, cache.read_marker(marker)['identity']['providers'])


    def test_provider_update_refuses_other_missing_snapshot_inventory(self):
        root, dump, snapshots = self.provider_update_fixture()
        marker = root / cache.COMPLETED_EXPANDER
        record = cache.read_marker(marker)
        del record['identity']['providers']['language-names.tsv']
        cache.write_private_marker(marker, record)
        proof = cache.prepare_wikibase_provider_update(root, dump, self.binding(root))
        self.assertIsNotNone(proof)
        hashes = self.stage_provider_update(root, snapshots, 'unsupported inventory')
        before = marker.read_bytes()
        with self.assertRaisesRegex(ValueError, 'Unsupported original Provider inventory'):
            cache.finish_wikibase_provider_update(proof, hashes)
        self.assertEqual(before, marker.read_bytes())


    def test_provider_update_rejects_native_source_tool_and_nonentity_drift(self):
        for kind in ('worker','program','module','plan','dump','receipt','namespace','other-provider','tool','leaf','abi','member','link','root-link','parent-member'):
            with self.subTest(kind=kind):
                root,dump,snapshots=self.provider_update_fixture()
                proof=cache.prepare_wikibase_provider_update(root,dump,self.binding(root))
                hashes=self.stage_provider_update(root,snapshots,'new')
                paths={'worker':root/'dict-bundle-expander','program':root/'lua-program.meta',
                    'module':root/'modules/123.lua','plan':root.parent/'compile-plan.tsv','dump':dump,
                    'receipt':root/'extraction-source.json','namespace':Path(snapshots['namespace-registry.tsv']),
                    'other-provider':Path(snapshots['interface-messages.tsv']),
                    'tool':Path(self.graph['llvm']),'leaf':Path(self.graph['leaf']),
                    'abi':self.project/cache.ABI_FILES[0],'member':root/'modules/extra.lua'}
                original_seal=(root/cache.COMPLETED_EXPANDER).read_bytes()
                if kind=='root-link':
                    moved=root.with_name('original-root');root.rename(moved);root.symlink_to(moved,target_is_directory=True)
                elif kind=='parent-member':
                    (root.parent/'unexpected').write_bytes(b'unknown output')
                elif kind=='link':
                    path=root/'wikibase-entities.tsv';target=cache.os.readlink(path)
                    path.unlink();path.symlink_to(str(Path(target).parent)+'/./'+Path(target).name)
                else:paths[kind].write_bytes(b'changed')
                with self.assertRaises((ValueError,OSError,KeyError)):
                    cache.finish_wikibase_provider_update(proof,hashes)
                self.assertEqual(cache.PROVIDER_UPDATE_MARKER,(root/'.incomplete').read_bytes())
                self.assertEqual(original_seal,(root/cache.COMPLETED_EXPANDER).read_bytes())

    def test_provider_update_requires_bound_complete_pair_and_exact_selected_bytes(self):
        root,dump,snapshots=self.fixture()
        self.assertIsNone(cache.prepare_wikibase_provider_update(root,dump,self.binding(root)))
        (root/'.incomplete').write_bytes(cache.PROVIDER_UPDATE_MARKER)
        with self.assertRaises(ValueError):
            cache.frozen_runtime_context(root,dump,self.binding(root),provider_update=True)
        for kind in ('missing-role','wrong-hash','changed-proof','wrong-root-marker'):
            with self.subTest(kind=kind):
                root,dump,snapshots=self.provider_update_fixture()
                proof=cache.prepare_wikibase_provider_update(root,dump,self.binding(root))
                hashes=self.stage_provider_update(root,snapshots,'new')
                if kind=='missing-role':hashes.pop('wikibase-entity-terms.tsv')
                elif kind=='wrong-hash':hashes['wikibase-entities.tsv']='0'*64
                elif kind=='changed-proof':proof['record']['identity']['producer']['runtime']=[1,'f'*64]
                else:(root/'.incomplete').write_bytes(b'building')
                with self.assertRaises(ValueError):cache.finish_wikibase_provider_update(proof,hashes)
                self.assertTrue((root/'.incomplete').exists())

    def test_provider_update_seal_write_failure_keeps_unready_original_proof(self):
        root,dump,snapshots=self.provider_update_fixture();original=self.binding(root)
        proof=cache.prepare_wikibase_provider_update(root,dump,original)
        hashes=self.stage_provider_update(root,snapshots,'new')
        failure=OSError('controlled seal failure')
        with mock.patch.object(cache,'write_private_marker',side_effect=failure):
            with self.assertRaises(OSError) as caught:cache.finish_wikibase_provider_update(proof,hashes)
        self.assertIs(failure,caught.exception)
        self.assertEqual(original,self.binding(root))
        self.assertEqual(cache.PROVIDER_UPDATE_MARKER,(root/'.incomplete').read_bytes())
        self.assertIsNone(cache.frozen_runtime_context(root,dump,original))

    def test_provider_update_repeated_generation_retains_first_native_origin(self):
        root,dump,snapshots=self.provider_update_fixture();original=self.binding(root)
        previous=original
        for value in ('second','third'):
            proof=cache.prepare_wikibase_provider_update(root,dump,previous)
            hashes=self.stage_provider_update(root,snapshots,value)
            current=cache.finish_wikibase_provider_update(proof,hashes)
            (root/'.incomplete').unlink();record=cache.frozen_runtime_context(root,dump,current)
            self.assertEqual(original,record['provider_update']['original_seal_sha256'])
            self.assertEqual(previous,record['provider_update']['previous_seal_sha256'])
            self.assertEqual(3,len(record['provider_update']))
            previous=current

    def test_parser_function_facts_optional_absence_preserves_seal(self):
        root,dump,snapshots=self.fixture()
        self.assertIn('parser-function-facts.json',snapshots)
        self.assertIsNone(snapshots['parser-function-facts.json'])
        record=cache.frozen_runtime_context(root,dump,self.binding(root))
        self.assertIsNone(record['identity']['providers']['parser-function-facts.json'])

    def test_parser_function_facts_selected_bytes_and_frozen_link_are_bound(self):
        name='parser-function-facts.json'
        for changed in ('none','undeclared','different-selection','content-after-seal','link-after-seal'):
            with self.subTest(changed=changed):
                root,dump,snapshots=self.fixture(ready=False)
                source=self.base/(str(self.sequence)+'-'+name)
                source.write_bytes(b'{"controlled-parser-function-facts":true}\n')
                snapshots[name]=str(source)
                (root/name).symlink_to(source)
                if changed=='undeclared':snapshots[name]=None
                if changed=='different-selection':
                    other=self.base/(str(self.sequence)+'-different-facts')
                    other.write_bytes(b'wrong selected snapshot')
                    snapshots[name]=str(other)
                if changed in ('undeclared','different-selection'):
                    with self.assertRaises(ValueError):self.call('seal-expander',root,dump,snapshots)
                    self.assertFalse((root/cache.COMPLETED_EXPANDER).exists())
                    continue
                self.assertEqual(0,self.call('seal-expander',root,dump,snapshots))
                record=cache.read_marker(root/cache.COMPLETED_EXPANDER)
                self.assertEqual(record['identity']['providers'][name],list(cache.stable_file_digest(source,snapshot=True)))
                binding=self.binding(root);cache.shutil.rmtree(root/'llvm')
                (root/'.incomplete').unlink();(root.parent/'.incomplete').write_bytes(b'expander ready')
                if changed=='content-after-seal':source.write_bytes(b'changed facts')
                elif changed=='link-after-seal':
                    (root/name).unlink();(root/name).symlink_to(str(source.parent)+'/./'+source.name)
                if changed=='none':self.assertEqual(record,cache.frozen_runtime_context(root,dump,binding))
                else:
                    with self.assertRaises(ValueError):cache.frozen_runtime_context(root,dump,binding)

    def test_page_language_optional_payloads_preserve_absence_and_prefix_selection(self):
        names=('page-language.json','page-language.raw.json','page-language.html')
        for count in (0,2,3):
            with self.subTest(count=count):
                root,dump,snapshots=self.fixture(ready=False)
                for i,name in enumerate(names):
                    self.assertIsNone(snapshots[name])
                    if i<count:
                        source=self.base/(str(self.sequence)+'-'+name)
                        source.write_bytes(b'controlled page-language payload')
                        snapshots[name]=str(source);(root/name).symlink_to(source)
                self.assertEqual(0,self.call('seal-expander',root,dump,snapshots))
                record=cache.read_marker(root/cache.COMPLETED_EXPANDER)
                for i,name in enumerate(names):
                    self.assertEqual(i<count,record['identity']['providers'][name] is not None)
                binding=self.binding(root);cache.shutil.rmtree(root/'llvm')
                (root/'.incomplete').unlink();(root.parent/'.incomplete').write_bytes(b'expander ready')
                self.assertEqual(record,cache.frozen_runtime_context(root,dump,binding))

    def test_page_language_selected_payloads_keep_existing_seal_and_frozen_refusals(self):
        names=('page-language.json','page-language.raw.json','page-language.html')
        for name in names:
            for changed in ('undeclared','different-selection','content-after-seal','link-after-seal','removed-after-seal','appeared-after-seal'):
                with self.subTest(name=name,changed=changed):
                    root,dump,snapshots=self.fixture(ready=False)
                    source=self.base/(str(self.sequence)+'-'+name)
                    source.write_bytes(b'controlled page-language payload')
                    if changed!='appeared-after-seal':
                        snapshots[name]=str(source);(root/name).symlink_to(source)
                    if changed=='undeclared':snapshots[name]=None
                    if changed=='different-selection':
                        other=self.base/(str(self.sequence)+'-different-language')
                        other.write_bytes(b'wrong selected snapshot');snapshots[name]=str(other)
                    if changed in ('undeclared','different-selection'):
                        with self.assertRaises(ValueError):self.call('seal-expander',root,dump,snapshots)
                        self.assertFalse((root/cache.COMPLETED_EXPANDER).exists())
                        continue
                    self.assertEqual(0,self.call('seal-expander',root,dump,snapshots))
                    binding=self.binding(root);cache.shutil.rmtree(root/'llvm')
                    (root/'.incomplete').unlink();(root.parent/'.incomplete').write_bytes(b'expander ready')
                    if changed=='content-after-seal':source.write_bytes(b'changed language')
                    elif changed=='link-after-seal':
                        (root/name).unlink();(root/name).symlink_to(str(source.parent)+'/./'+source.name)
                    elif changed=='removed-after-seal':(root/name).unlink()
                    elif changed=='appeared-after-seal':(root/name).symlink_to(source)
                    with self.assertRaises(ValueError):cache.frozen_runtime_context(root,dump,binding)
                    self.assertEqual(binding,self.binding(root))

    def figure_fixture(self):
        root,dump,snapshots=self.fixture(ready=False)
        names=('figure-siteinfo.raw.json','figure-sizing.json','figure-sizing.raw.json','figure-sizing.site.json')
        for name in names:
            self.assertIn(name,snapshots)
            source=self.base/(str(self.sequence)+'-'+name)
            source.write_bytes(('source-backed '+name).encode())
            snapshots[name]=str(source)
            (root/name).symlink_to(source)
        return root,dump,snapshots,names

    def test_figure_snapshots_stage_and_seal_exact_installed_roles(self):
        root,dump,snapshots,names=self.figure_fixture()
        self.assertEqual(0,self.call('seal-expander',root,dump,snapshots))
        record=cache.read_marker(root/cache.COMPLETED_EXPANDER)
        assets={name:[size,digest] for name,size,digest in record['identity']['assets']}
        for name in names:
            source=Path(snapshots[name])
            self.assertEqual(source.read_bytes(),(root/name).read_bytes())
            self.assertEqual(record['identity']['providers'][name],list(cache.stable_file_digest(source,snapshot=True)))
            self.assertEqual(assets[name],cache.stable_file_digest(source,snapshot=True))
            self.assertEqual(record['runtime_stamps']['snapshot_links'][name],str(source))
        cache.shutil.rmtree(root/'llvm')
        (root/'.incomplete').unlink();(root.parent/'.incomplete').write_bytes(b'expander ready')
        self.assertEqual(record,cache.frozen_runtime_context(root,dump,self.binding(root)))

    def test_figure_snapshots_reject_changed_selection_content_or_link(self):
        for name in ('figure-siteinfo.raw.json','figure-sizing.json','figure-sizing.raw.json','figure-sizing.site.json'):
            for changed in ('undeclared','different-selected-bytes','removed','content-after-seal','link-after-seal'):
                with self.subTest(role=name,changed=changed):
                    root,dump,snapshots,_=self.figure_fixture()
                    installed=root/name
                    if changed=='undeclared':snapshots[name]=None
                    elif changed=='different-selected-bytes':
                        other=self.base/(str(self.sequence)+'-different');other.write_bytes(b'wrong source')
                        snapshots[name]=str(other)
                    elif changed=='removed':installed.unlink()
                    if changed in ('undeclared','different-selected-bytes','removed'):
                        with self.assertRaises((ValueError,FileNotFoundError)):
                            self.call('seal-expander',root,dump,snapshots)
                        self.assertFalse((root/cache.COMPLETED_EXPANDER).exists())
                        continue
                    self.assertEqual(0,self.call('seal-expander',root,dump,snapshots))
                    binding=self.binding(root)
                    cache.shutil.rmtree(root/'llvm')
                    (root/'.incomplete').unlink();(root.parent/'.incomplete').write_bytes(b'expander ready')
                    source=Path(snapshots[name])
                    if changed=='content-after-seal':
                        before=source.stat();raw=source.read_bytes()
                        source.write_bytes(bytes([raw[0]^1])+raw[1:])
                        cache.os.utime(source,ns=(before.st_atime_ns,before.st_mtime_ns))
                    else:
                        installed.unlink();installed.symlink_to(str(source.parent)+'/./'+source.name)
                    with self.assertRaises(ValueError):cache.frozen_runtime_context(root,dump,binding)
                    self.assertTrue((root/'dict-bundle-expander').exists())





    def test_link_order_and_paired_leaf_refuse_sealing(self):
        for changed in ('order','leaf','metadata'):
            with self.subTest(changed=changed):
                root,dump,snapshots=self.fixture(ready=False)
                if changed=='order':
                    path=root/'llvm/module-objects.rsp';path.write_text(''.join(reversed(path.read_text().splitlines(keepends=True))))
                elif changed=='leaf':Path(self.graph['leaf']).write_bytes(b'wrong leaf')
                else:(root/'lua-program.meta').write_bytes(b'wrong metadata')
                with self.assertRaises(ValueError):self.call('seal-expander',root,dump,snapshots)
                self.assertFalse((root/cache.COMPLETED_EXPANDER).exists())

    def test_failed_certificate_publication_never_creates_ready_proof(self):
        root,dump,snapshots=self.fixture(ready=False)
        failure=OSError('certificate publication failure')
        with mock.patch.object(cache,'write_private_marker',side_effect=failure):
            with self.assertRaises(OSError) as caught:self.call('seal-expander',root,dump,snapshots)
        self.assertIs(failure,caught.exception)
        self.assertFalse((root/cache.COMPLETED_EXPANDER).exists())
        self.assertEqual(b'building',(root/'.incomplete').read_bytes())
        self.assertEqual(b'linking',(root.parent/'.incomplete').read_bytes())


    def test_frozen_runtime_context_uses_seal_metadata_not_current_graph_or_payloads(self):
        root,dump,snapshots=self.fixture();binding=self.binding(root)
        original=cache.stable_file_digest;reads=[]
        def observed(path,**kwargs):
            reads.append(Path(path).name)
            return original(path,**kwargs)
        with mock.patch.object(cache,'completed_producer_identity',side_effect=AssertionError('new graph observation')), mock.patch.object(cache,'stable_file_digest',side_effect=observed), mock.patch.object(cache.shutil,'rmtree',side_effect=AssertionError('retirement forbidden')):
            record=cache.frozen_runtime_context(root,dump,binding)
        self.assertEqual(record['provenance'],'ordinary-linked-expander')
        self.assertEqual(set(record['runtime_stamps']['assets']),cache.completed_asset_names(root))
        self.assertTrue(set(reads)<={'namespace-registry.tsv','transclusion-redirects.tsv'})
        self.assertNotIn('lua-program.meta',reads)
        self.assertEqual(binding,self.binding(root))

    def test_legacy_or_unready_seal_never_authorizes_frozen_source(self):
        root,dump,snapshots=self.fixture();path=root/cache.COMPLETED_EXPANDER
        original=path.read_bytes();record=json.loads(original);record.pop('runtime_stamps')
        path.write_text(json.dumps(record))
        self.assertIsNone(cache.frozen_runtime_context(root,dump,self.binding(root)))
        path.write_bytes(original);(root.parent/'.incomplete').write_bytes(b'building')
        self.assertIsNone(cache.frozen_runtime_context(root,dump,self.binding(root)))
        self.assertTrue((root/'dict-bundle-expander').exists())
        with self.assertRaises(ValueError):cache.frozen_runtime_context(root,dump,'0'*64)

    def test_frozen_context_rejects_worker_meta_module_link_and_inventory_drift(self):
        import os
        for case in ['worker','meta','module','snapshot-link','extra','typed-stamp']:
            with self.subTest(case=case):
                root,dump,snapshots=self.fixture();binding=self.binding(root)
                if case in ('worker','meta','module'):
                    path=root/{'worker':'dict-bundle-expander','meta':'lua-program.meta','module':'modules/123.lua'}[case]
                    old=path.stat();raw=path.read_bytes();path.write_bytes(bytes([raw[0]^1])+raw[1:]);os.utime(path,ns=(old.st_atime_ns,old.st_mtime_ns))
                elif case=='snapshot-link':
                    path=root/'namespace-registry.tsv';target=os.readlink(path);path.unlink();path.symlink_to(str(Path(target).parent)+'/./'+Path(target).name)
                elif case=='extra':(root/'modules/999.lua').write_bytes(b'return 9')
                else:
                    path=root/cache.COMPLETED_EXPANDER;record=json.loads(path.read_text());record['runtime_stamps']['assets']['dict-bundle-expander'][0]=True;path.write_text(json.dumps(record));binding=self.binding(root)
                with self.assertRaises(ValueError):cache.frozen_runtime_context(root,dump,binding)
                self.assertTrue((root/'dict-bundle-expander').exists())

    def test_frozen_context_brackets_source_receipt_validation_with_final_stamps(self):
        import os
        original=cache.completed_source_binding
        for case in ['worker','meta','module','plan','snapshot-link']:
            with self.subTest(case=case):
                root,dump,snapshots=self.fixture();binding=self.binding(root)
                def changed(*args,**kwargs):
                    result=original(*args,**kwargs)
                    if case=='snapshot-link':
                        path=root/'namespace-registry.tsv';target=os.readlink(path);path.unlink();path.symlink_to(str(Path(target).parent)+'/./'+Path(target).name)
                    else:
                        path={'worker':root/'dict-bundle-expander','meta':root/'lua-program.meta','module':root/'modules/123.lua','plan':root.parent/'compile-plan.tsv'}[case]
                        before=path.stat();raw=path.read_bytes();path.write_bytes(bytes([raw[0]^1])+raw[1:]);os.utime(path,ns=(before.st_atime_ns,before.st_mtime_ns))
                    return result
                with mock.patch.object(cache,'completed_source_binding',side_effect=changed):
                    with self.assertRaises(ValueError):cache.frozen_runtime_context(root,dump,binding)
                self.assertTrue((root/'dict-bundle-expander').exists())




class ObjectCacheTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / "cache"
        self.project = self.base / "project"
        for name in cache.ABI_FILES:
            path = self.project / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(name)
        for name in cache.LIVE_LEAF_SOURCE_PATHS:
            path = self.project / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(name)
        self.flags = ["-march=native", "-fno-lto", "-Wno-override-module", "-O1"]
        self.tool = {"tool": {"extractor_sha256": "c" * 64, "libraries": []},
                     "target": "x86_64-linux-gnu", "version": "clang fixture"}
        self.patched = mock.patch.object(cache, "clang_identity", return_value=self.tool)
        self.patched.start()
        self.addCleanup(self.patched.stop)
        self.zig_tool = {"tool_sha256": "e" * 64, "version": "zig fixture",
                         "target": "x86_64-linux-gnu", "flags": list(cache.LEAF_CONTRACT_FLAGS)}
        self.patched_zig = mock.patch.object(cache, "live_zig_observation", return_value=self.zig_tool)
        self.patched_zig.start()
        self.addCleanup(self.patched_zig.stop)

    def llvm(self, name):
        root = self.base / name
        root.mkdir()
        (root / "batch-plan.tsv").write_text(
            "# dict-llvm-batch-plan-v1\n"
            "-O2\tmodule_batch_o2_000000.bc\t1\t0\t0\t10\n"
            "-O0\tmodule_batch_o0_000000.bc\t1\t1\t1\t5\n")
        (root / "module_batch_o2_000000.bc").write_bytes(b"batch-high")
        (root / "module_batch_o0_000000.bc").write_bytes(b"batch-low")
        (root / "program.bc").write_bytes(b"program bitcode")
        (root / "program.meta").write_bytes(b"program metadata")
        (root / "value_leaf.bc").write_bytes(b"verified build-only helper bitcode")
        return root

    names = ("module_batch_000000.o", "module_batch_000001.o", "program.o")

    def probe(self, output, flags=None):
        return cache.probe_objects(self.root, "clang", self.project, output,
                                   self.flags if flags is None else flags)

    def publish(self, output, flags=None):
        return cache.publish_objects(self.root, output, "clang",
                                     self.flags if flags is None else flags)

    def complete_missing(self, output):
        for name in self.names:
            path = output / name
            if not path.exists():
                path.write_bytes(name.encode())

    def seed(self):
        first = self.llvm("first")
        self.assertEqual(cache.MISS, self.probe(first))
        self.assertEqual("000\n", (first / ".object-hits").read_text())
        self.complete_missing(first)
        self.assertEqual(0, self.publish(first))
        snapshot = cache.read_marker(first / ".object-identity.json")
        self.entries = dict(cache.object_entries(snapshot["identity"]))
        return first

    def entry(self, name):
        return cache.object_cache_path(self.root, self.entries[name])

    def assert_hits(self, output, bits, flags=None):
        expected = 0 if bits == "111" else cache.MISS
        self.assertEqual(expected, self.probe(output, flags))
        self.assertEqual(bits + "\n", (output / ".object-hits").read_text())
        for name, hit in zip(self.names, bits):
            self.assertEqual(hit == "1", (output / name).is_file(), name)

    def zero_llvm(self, name):
        root = self.llvm(name)
        (root / "batch-plan.tsv").write_text(
            "# dict-llvm-batch-plan-v1\n"
            "# opt\tfile\tcount\tfirst\tlast\tsource_bytes\n")
        for filename in ("module_batch_o2_000000.bc", "module_batch_o0_000000.bc"):
            (root / filename).unlink()
        return root

    def test_zero_batches_cache_only_program_and_allow_consumed_bitcode(self):
        first = self.zero_llvm("zero-first")
        self.assertEqual([], cache.read_object_plan(first))
        self.assertEqual(cache.MISS, self.probe(first))
        self.assertEqual("0\n", (first / ".object-hits").read_text())
        identity = json.loads((first / ".object-identity.json").read_text())["identity"]
        self.assertEqual(["program.o"], cache.object_names(identity))
        self.assertEqual(["program.o"], [name for name, _ in cache.object_entries(identity)])
        with self.assertRaises(ValueError):
            self.publish(first)
        (first / "program.o").write_bytes(b"zero-module native program")
        # Clang consumes bitcode; publication uses the authenticated pre-probe identity.
        (first / "program.bc").unlink()
        self.assertEqual(0, self.publish(first))
        second = self.zero_llvm("zero-second")
        self.assertEqual(0, self.probe(second))
        self.assertEqual("1\n", (second / ".object-hits").read_text())
        self.assertEqual(b"zero-module native program", (second / "program.o").read_bytes())
        self.assertEqual([], list(second.glob("module_batch_*.o")))

    def test_zero_batches_require_framing_and_all_program_inputs(self):
        for index, contents in enumerate(("", "# unrelated\n", "# dict-llvm-batch-plan-v1\n",
                                          "# dict-llvm-batch-plan-v1\n-O2\tbroken\n")):
            with self.subTest(plan=contents):
                root = self.zero_llvm("zero-bad-plan-" + str(index))
                (root / "batch-plan.tsv").write_text(contents)
                with self.assertRaises(ValueError):
                    self.probe(root)
                self.assertFalse((root / ".object-hits").exists())
        for index, name in enumerate(("program.bc", "program.meta", "value_leaf.bc")):
            with self.subTest(missing=name):
                root = self.zero_llvm("zero-missing-" + str(index))
                (root / name).unlink()
                with self.assertRaises((ValueError, FileNotFoundError)):
                    self.probe(root)
                self.assertFalse((root / ".object-hits").exists())

    def test_zero_batches_reject_corrupt_program_and_changed_publication_metadata(self):
        first = self.zero_llvm("zero-seed")
        self.assertEqual(cache.MISS, self.probe(first))
        (first / "program.o").write_bytes(b"zero-module native program")
        self.assertEqual(0, self.publish(first))
        restored = self.zero_llvm("zero-corrupt")
        self.assertEqual(0, self.probe(restored))
        (restored / "program.o").write_bytes(b"corrupt")
        repaired = self.zero_llvm("zero-repaired")
        self.assertEqual(cache.MISS, self.probe(repaired))
        self.assertEqual("0\n", (repaired / ".object-hits").read_text())
        (repaired / "program.o").write_bytes(b"")
        with self.assertRaises(ValueError):
            self.publish(repaired)
        (repaired / "program.o").write_bytes(b"repaired native program")
        self.assertEqual(0, self.publish(repaired))
        final = self.zero_llvm("zero-final")
        self.assertEqual(0, self.probe(final))
        self.assertEqual(b"repaired native program", (final / "program.o").read_bytes())
        for index, name in enumerate(("batch-plan.tsv", "program.meta")):
            with self.subTest(changed=name):
                root = self.zero_llvm("zero-publish-change-" + str(index))
                self.assertEqual(0, self.probe(root))
                with (root / name).open("a") as stream:
                    stream.write("changed")
                with self.assertRaises(ValueError):
                    self.publish(root)

    def nonimporting_llvm(self, name, with_batch):
        if not with_batch:
            return self.zero_llvm(name)
        root = self.llvm(name)
        (root / "batch-plan.tsv").write_text(
            "# dict-llvm-batch-plan-v1\n"
            "-O0\tmodule_batch_o0_000000.bc\t1\t1\t1\t5\n")
        (root / "module_batch_o2_000000.bc").unlink()
        return root

    def test_nonimporting_plans_reuse_existing_objects_without_live_zig(self):
        first = self.seed()  # Mixed plan records the full legacy live observation.
        original = cache.read_marker(first / ".object-identity.json")["identity"]
        outputs = []
        for with_batch in (False, True):
            with self.subTest(with_batch=with_batch), mock.patch.object(
                    cache, "live_zig_observation", side_effect=AssertionError("unused Zig probe")):
                output = self.nonimporting_llvm("no-zig-" + str(with_batch), with_batch)
                self.assertEqual(0, self.probe(output))
                self.assertEqual("11\n" if with_batch else "1\n",
                                 (output / ".object-hits").read_text())
                snapshot = cache.read_marker(output / ".object-identity.json")["identity"]
                self.assertEqual({key: value for key, value in original["value_leaf"].items()
                                  if key != "live_zig_observation"}, snapshot["value_leaf"])
                entries = dict(cache.object_entries(snapshot))
                self.assertEqual(self.entries["program.o"], entries["program.o"])
                self.assertEqual(b"program.o", (output / "program.o").read_bytes())
                if with_batch:
                    self.assertEqual(self.entries[self.names[1]], entries[self.names[0]])
                    self.assertEqual(self.names[1].encode(), (output / self.names[0]).read_bytes())
                outputs.append(output)
        # Publication prunes unused keys; prove both restorations before either prune.
        for output in outputs:
            self.assertEqual(0, self.publish(output))

    def test_nonimporting_plans_keep_leaf_and_publication_guards(self):
        with mock.patch.object(cache, "live_zig_observation",
                               side_effect=AssertionError("unused Zig probe")):
            for with_batch in (False, True):
                for missing in ("value_leaf.bc", cache.LIVE_LEAF_SOURCE_PATHS[0]):
                    with self.subTest(with_batch=with_batch, missing=missing):
                        output = self.nonimporting_llvm("missing-" + str(with_batch) +
                                                       "-" + Path(missing).name, with_batch)
                        path = output / missing if missing == "value_leaf.bc" else self.project / missing
                        original = path.read_bytes()
                        path.unlink()
                        try:
                            with self.assertRaises((ValueError, FileNotFoundError)):
                                self.probe(output)
                        finally:
                            path.write_bytes(original)
                        self.assertFalse((output / ".object-identity.json").exists())
                        self.assertFalse((output / ".object-hits").exists())
                for changed in ("value_leaf.bc", "program.meta", "batch-plan.tsv", "clang"):
                    with self.subTest(with_batch=with_batch, changed=changed):
                        output = self.nonimporting_llvm("changed-" + str(with_batch) +
                                                       "-" + changed, with_batch)
                        self.assertEqual(cache.MISS, self.probe(output))
                        snapshot = cache.read_marker(output / ".object-identity.json")["identity"]
                        for name in cache.object_names(snapshot):
                            (output / name).write_bytes(name.encode())
                        if changed == "clang":
                            with mock.patch.object(cache, "clang_identity",
                                                   return_value=dict(self.tool, version="changed Clang")):
                                with self.assertRaisesRegex(ValueError, "native target"):
                                    self.publish(output)
                        else:
                            (output / changed).write_bytes(b"changed during compilation")
                            with self.assertRaisesRegex(ValueError, "changed during compilation"):
                                self.publish(output)
                        self.assertFalse((self.root / "objects").exists())

    def test_optimized_batches_require_full_live_zig_observation_before_restore(self):
        for mode in ("-O1", "-O2"):
            with self.subTest(mode=mode):
                output = self.llvm("optimized-" + mode)
                plan = output / "batch-plan.tsv"
                plan.write_text(plan.read_text().replace("-O2\t", mode + "\t"))
                with mock.patch.object(cache, "live_zig_observation",
                                       side_effect=ValueError("Zig observation unavailable")):
                    with self.assertRaisesRegex(ValueError, "Zig observation unavailable"):
                        self.probe(output)
                self.assertFalse((output / ".object-identity.json").exists())
                self.assertFalse((output / ".object-hits").exists())
                self.assertFalse(any((output / name).exists() for name in self.names))
                self.assertEqual(cache.MISS, self.probe(output))
                snapshot = cache.read_marker(output / ".object-identity.json")["identity"]
                full_leaf = cache.value_leaf_identity(output, self.project, "zig")
                self.assertEqual(full_leaf, snapshot["value_leaf"])
                entries = dict(cache.object_entries(snapshot))
                self.assertEqual({key: value for key, value in full_leaf.items()
                                  if key != "live_zig_observation"}, entries[self.names[0]]["value_leaf"])
                self.assertEqual(self.zig_tool, snapshot["value_leaf"]["live_zig_observation"])
                self.assertNotIn("value_leaf", entries[self.names[1]])
                self.assertNotIn("value_leaf", entries["program.o"])

    def test_round_trip_corruption_is_local_and_can_be_repaired(self):
        self.seed()
        second = self.llvm("second")
        self.assert_hits(second, "111")
        self.assertEqual(b"module_batch_000001.o",
                         (second / "module_batch_000001.o").read_bytes())
        # The installed output is a hardlink: corruption must invalidate only
        # its own content entry, not otherwise unchanged batches/program.
        (second / "module_batch_000001.o").write_bytes(b"bad")
        third = self.llvm("third")
        self.assert_hits(third, "101")
        self.complete_missing(third)
        self.assertEqual(0, self.publish(third))
        self.assert_hits(self.llvm("fourth"), "111")

    def test_one_batch_changed_restores_other_batch_and_program(self):
        self.seed()
        changed = self.llvm("changed")
        (changed / "module_batch_o2_000000.bc").write_bytes(b"different function IDs/body")
        self.assert_hits(changed, "011")
        cached = self.entry("module_batch_000001.o") / "object.o"
        self.assertEqual(cached.stat().st_ino,
                         (changed / "module_batch_000001.o").stat().st_ino)

    def test_metadata_only_change_does_not_invalidate_native_objects(self):
        self.seed()
        changed = self.llvm("changed")
        (changed / "program.meta").write_bytes(b"fresh runtime metadata")
        plan = changed / "batch-plan.tsv"
        plan.write_text(plan.read_text() + "# fresh non-native plan annotation\n")
        self.assert_hits(changed, "111")
        self.assertEqual(0, self.publish(changed))
        self.assertEqual(b"fresh runtime metadata", (changed / "program.meta").read_bytes())

    def test_program_bitcode_change_invalidates_only_program(self):
        self.seed()
        changed = self.llvm("changed")
        (changed / "program.bc").write_bytes(b"new roots")
        self.assert_hits(changed, "110")

    def test_batch_mode_and_program_mode_are_independent_inputs(self):
        self.seed()
        changed = self.llvm("batch-mode")
        plan = changed / "batch-plan.tsv"
        plan.write_text(plan.read_text().replace("-O2\t", "-O1\t"))
        self.assert_hits(changed, "011")
        self.assert_hits(self.llvm("program-mode"), "110", self.flags[:-1] + ["-O2"])

    def test_reordered_batches_reuse_content_in_fresh_link_order(self):
        self.seed()
        changed = self.llvm("changed")
        plan = changed / "batch-plan.tsv"
        header, high, low = plan.read_text().splitlines()
        plan.write_text("\n".join((header, low, high)) + "\n")
        self.assert_hits(changed, "111")
        self.assertEqual(b"module_batch_000001.o", (changed / self.names[0]).read_bytes())
        self.assertEqual(b"module_batch_000000.o", (changed / self.names[1]).read_bytes())
        self.assertEqual(0, self.publish(changed))

    def test_abi_source_only_change_is_provenance_and_still_hits(self):
        self.seed()
        published = cache.read_marker(self.entry(self.names[0]) / ".complete.json")
        self.assertEqual("live-source-observation", published["provenance"]["abi_scope"])
        (self.project / cache.ABI_FILES[0]).write_text("changed runtime ABI source")
        changed = self.llvm("changed")
        self.assert_hits(changed, "111")
        snapshot = cache.read_marker(changed / ".object-identity.json")
        self.assertEqual(cache.abi_provenance(self.project), snapshot["provenance"]["abi"])
        self.assertEqual("live-source-observation", snapshot["provenance"]["abi_scope"])
        for _, identity in cache.object_entries(snapshot["identity"]):
            self.assertNotIn("abi", identity)

    def test_leaf_inputs_invalidate_only_optimized_batches(self):
        self.seed()
        changed = self.llvm("leaf-bitcode")
        (changed / "value_leaf.bc").write_bytes(b"different leaf definitions")
        self.assert_hits(changed, "011")
        source = self.project / cache.LIVE_LEAF_SOURCE_PATHS[1]
        source.write_text("changed helper source")
        self.assert_hits(self.llvm("leaf-source"), "011")
        source.write_text(cache.LIVE_LEAF_SOURCE_PATHS[1])
        for label, value in (("version", "new Zig"), ("target", "aarch64-linux-gnu"),
                             ("flags", ["-O2"]), ("tool_sha256", "f" * 64)):
            with self.subTest(label=label), mock.patch.object(
                    cache, "live_zig_observation", return_value=dict(self.zig_tool, **{label: value})):
                output = self.llvm("leaf-" + label)
                self.assert_hits(output, "111")
                snapshot = cache.read_marker(output / ".object-identity.json")["identity"]
                self.assertEqual(value, snapshot["value_leaf"]["live_zig_observation"][label])
                self.assertNotIn("live_zig_observation",
                                 dict(cache.object_entries(snapshot))[self.names[0]]["value_leaf"])

    def test_kernel_only_live_zig_observation_hits_but_loaded_clang_library_misses(self):
        self.zig_tool["target"] = "x86_64-linux.7.2.11...7.2.11-gnu.2.44"
        self.seed()
        changed_zig = dict(self.zig_tool, target="x86_64-linux.7.2.15...7.2.15-gnu.2.44")
        with mock.patch.object(cache, "live_zig_observation", return_value=changed_zig):
            output = self.llvm("kernel-only")
            self.assert_hits(output, "111")
            snapshot = cache.read_marker(output / ".object-identity.json")["identity"]
            self.assertEqual(changed_zig, snapshot["value_leaf"]["live_zig_observation"])
            self.assertEqual(self.entries, dict(cache.object_entries(snapshot)))
            self.assertEqual(0, self.publish(output))
        for name, tool in (("library", dict(self.tool, tool=dict(
                self.tool["tool"], libraries=[["/usr/lib/libz.so.1", "f" * 64]]))),
                ("executable", dict(self.tool, tool=dict(
                    self.tool["tool"], extractor_sha256="d" * 64)))):
            with self.subTest(name=name), mock.patch.object(cache, "clang_identity", return_value=tool):
                self.assert_hits(self.llvm("real-tool-" + name), "000")

    def test_live_observations_do_not_claim_to_have_produced_cached_leaf(self):
        output = self.llvm("paired-build-artifact")
        before = cache.value_leaf_identity(output, self.project, "zig")
        source = self.project / cache.LIVE_LEAF_SOURCE_PATHS[1]
        source.write_text("new live source after cached pipeline was built")
        with mock.patch.object(cache, "live_zig_observation",
                               return_value=dict(self.zig_tool, version="new live Zig")):
            after = cache.value_leaf_identity(output, self.project, "zig")
        self.assertEqual(before["bitcode"], after["bitcode"])
        self.assertEqual(set(after), {"bitcode", "live_source_observations", "live_zig_observation"})
        self.assertNotEqual(before["live_source_observations"], after["live_source_observations"])
        self.assertNotEqual(before["live_zig_observation"], after["live_zig_observation"])
        self.assertEqual(cache.sha256(source),
                         dict(after["live_source_observations"])[cache.LIVE_LEAF_SOURCE_PATHS[1]])

    def test_legacy_leaf_labels_cannot_redeem_optimized_objects(self):
        output = self.llvm("legacy")
        snapshot = cache.object_identity(output, "clang", self.project, self.flags)
        leaf = snapshot["value_leaf"]
        snapshot["value_leaf"] = {
            "bitcode": leaf["bitcode"],
            "producer_sources": leaf["live_source_observations"],
            "zig": leaf["live_zig_observation"],
        }
        for name, identity in cache.object_entries(snapshot):
            entry = cache.object_cache_path(self.root, identity)
            entry.mkdir(parents=True)
            asset = entry / "object.o"
            asset.write_bytes(name.encode())
            (entry / ".complete.json").write_text(cache.json.dumps({
                "identity": identity, "object": cache.record_object(asset),
                "provenance": {"abi": cache.abi_provenance(self.project)},
            }))
        # O0/program consume no leaf; their exact existing content keys survive.
        self.assert_hits(self.llvm("current"), "011")

    def test_compiler_target_features_and_common_flags_invalidate_every_object(self):
        self.seed()
        for label, value in (("version", "new Clang"), ("target", "aarch64-linux-gnu"),
                             ("tool", {"extractor_sha256": "f" * 64, "libraries": []}),
                             ("resolved_native", {"cpu": "alderlake", "features": ["+avx2"]})):
            with self.subTest(label=label), mock.patch.object(
                    cache, "clang_identity", return_value=dict(self.tool, **{label: value})):
                self.assert_hits(self.llvm("clang-" + label), "000")
        self.assert_hits(self.llvm("flags"), "000", ["-march=x86-64", *self.flags[1:]])

    def test_publish_rechecks_compiler_native_features_and_flags(self):
        first = self.llvm("first")
        self.probe(first)
        self.complete_missing(first)
        changed_tool = dict(self.tool, resolved_native={"cpu": "alderlake", "features": ["+avx2"]})
        with mock.patch.object(cache, "clang_identity", return_value=changed_tool):
            with self.assertRaisesRegex(ValueError, "native target"):
                self.publish(first)
        with self.assertRaisesRegex(ValueError, "compile flags"):
            self.publish(first, self.flags[:-1] + ["-O2"])
        self.assertFalse((self.root / "objects").exists())

    def test_publish_rechecks_plan_metadata_and_leaf(self):
        for name in ("batch-plan.tsv", "program.meta", "value_leaf.bc"):
            with self.subTest(name=name):
                output = self.llvm(name)
                self.probe(output)
                self.complete_missing(output)
                (output / name).write_bytes(b"changed while compiling")
                with self.assertRaisesRegex(ValueError, "changed during compilation"):
                    self.publish(output)
        self.assertFalse((self.root / "objects").exists())

    def test_compiled_bitcode_may_be_deleted_before_publication(self):
        first = self.llvm("first")
        self.probe(first)
        self.complete_missing(first)
        for name in ("module_batch_o2_000000.bc", "module_batch_o0_000000.bc", "program.bc"):
            (first / name).unlink()
        self.assertEqual(0, self.publish(first))
        self.assert_hits(self.llvm("second"), "111")

    def test_changed_restored_hardlink_cannot_be_recertified(self):
        self.seed()
        changed = self.llvm("changed")
        self.assert_hits(changed, "111")
        (changed / "program.o").write_bytes(b"changed after probe")
        with self.assertRaisesRegex(ValueError, "Restored native object changed"):
            self.publish(changed)
        self.assert_hits(self.llvm("third"), "110")

    def test_preexisting_output_rejected_before_any_restore(self):
        self.seed()
        changed = self.llvm("changed")
        (changed / "program.o").write_bytes(b"unverified object")
        with self.assertRaisesRegex(ValueError, "Refusing to replace"):
            self.probe(changed)
        self.assertFalse((changed / self.names[0]).exists())
        self.assertFalse((changed / ".object-hits").exists())

    def test_nonregular_oversized_empty_or_extra_cache_assets_are_local_misses(self):
        self.seed()
        target = self.entry(self.names[0])
        original = (target / "object.o").read_bytes()
        for label in ("symlink", "oversize", "empty", "extra"):
            with self.subTest(label=label), mock.patch.object(cache, "MAX_OBJECT_BYTES", 64):
                asset = target / "object.o"
                asset.unlink()
                if label == "symlink":
                    outside = self.base / "outside"
                    outside.write_bytes(original)
                    asset.symlink_to(outside)
                elif label == "oversize":
                    with asset.open("wb") as stream:
                        stream.truncate(65)
                else:
                    asset.write_bytes(b"" if label == "empty" else original)
                if label == "extra":
                    (target / "extra").write_text("not allowed")
                self.assert_hits(self.llvm(label), "011")
            (target / "extra").unlink(missing_ok=True)
        (target / "object.o").unlink()
        (target / "object.o").write_bytes(original)

    def test_invalid_and_oversized_cache_markers_are_local_misses(self):
        first = self.seed()
        marker = self.entry(self.names[0]) / ".complete.json"
        for label, raw in (("list", "[]"), ("identity", '{}'), ("invalid", "{")):
            marker.write_text(raw)
            self.assert_hits(self.llvm(label), "011")
        bound = max(4096, (first / ".object-identity.json").stat().st_size * 2)
        marker.write_bytes(b" " * (bound + 1))
        with mock.patch.object(cache, "MAX_MARKER_BYTES", bound):
            self.assert_hits(self.llvm("oversized"), "011")

    def test_incomplete_or_symlink_cache_entry_never_hits(self):
        first = self.llvm("first")
        snapshot = cache.object_identity(first, "clang", self.project, self.flags)
        entries = list(cache.object_entries(snapshot))
        target = cache.object_cache_path(self.root, entries[0][1])
        target.mkdir(parents=True)
        (target / "object.o").write_bytes(b"incomplete")
        self.assert_hits(first, "000")
        cache.shutil.rmtree(target)
        outside = self.base / "outside"
        outside.mkdir()
        target.symlink_to(outside, target_is_directory=True)
        self.assert_hits(self.llvm("second"), "000")

    def test_private_snapshot_bounds_shape_and_version_are_rejected(self):
        first = self.llvm("first")
        self.probe(first)
        self.complete_missing(first)
        marker = first / ".object-identity.json"
        original = cache.read_marker(marker)
        for label, value in (("list", []), ("shape", {"identity": []}),
                             ("old", dict(original, identity=dict(original["identity"], version=3))),
                             ("program", dict(original, identity=dict(original["identity"], program_bc=None))),
                             ("restored", dict(original, restored=[["../bad", 1, "a" * 64]]))):
            with self.subTest(label=label):
                marker.write_text(cache.json.dumps(value))
                with self.assertRaises(ValueError):
                    self.publish(first)
        with mock.patch.object(cache, "MAX_MARKER_BYTES", 64):
            marker.write_bytes(b" " * 65)
            with self.assertRaisesRegex(ValueError, "Oversized"):
                self.publish(first)

    def test_success_retains_shared_keys_and_prunes_old_and_legacy_keys(self):
        self.seed()
        old = {self.entry(name) for name in self.names}
        legacy = self.root / "objects" / ("f" * 64)
        legacy.mkdir()
        (legacy / ".complete.json").write_text("old generation")
        changed = self.llvm("changed")
        (changed / "module_batch_o2_000000.bc").write_bytes(b"new batch")
        self.assert_hits(changed, "011")
        # An incomplete producer cannot delete the previous successful set.
        with self.assertRaises(ValueError):
            self.publish(changed)
        self.assertTrue(all(path.exists() for path in old))
        self.complete_missing(changed)
        self.assertEqual(0, self.publish(changed))
        self.assertFalse(legacy.exists())
        self.assertFalse(self.entry(self.names[0]).exists())
        self.assertTrue(self.entry(self.names[1]).exists())
        self.assertTrue(self.entry(self.names[2]).exists())
        self.assertEqual(3, len(list((self.root / "objects").iterdir())))

    def test_failed_atomic_publish_preserves_previous_keys(self):
        self.seed()
        previous = {path.name for path in (self.root / "objects").iterdir()}
        changed = self.llvm("changed")
        (changed / "module_batch_o2_000000.bc").write_bytes(b"new batch")
        self.assert_hits(changed, "011")
        self.complete_missing(changed)
        rename = Path.rename
        def fail_publish(path, destination):
            if path.name.startswith(".part-"):
                raise OSError("injected atomic publication failure")
            return rename(path, destination)
        with mock.patch.object(Path, "rename", fail_publish):
            with self.assertRaisesRegex(OSError, "injected"):
                self.publish(changed)
        self.assertEqual(previous, {path.name for path in (self.root / "objects").iterdir()})

    def test_old_object_version_cannot_redeem_current_objects(self):
        first = self.llvm("first")
        snapshot = cache.object_identity(first, "clang", self.project, self.flags)
        for _, current in cache.object_entries(snapshot):
            old = dict(current, version=3)
            root = cache.object_cache_path(self.root, old)
            root.mkdir(parents=True)
            (root / "object.o").write_bytes(b"old object")
            (root / ".complete.json").write_text(cache.json.dumps({
                "identity": old, "object": cache.record_object(root / "object.o"),
                "provenance": {"abi": cache.abi_provenance(self.project)},
            }))
        self.assert_hits(first, "000")


class IdentityProbeDeadlineTest(unittest.TestCase):
    def test_actual_watchdog_child_environment_overrides_ambient_deadline(self):
        import ast
        source = Path(__file__).with_name('build_resource_limits.py').read_text()
        compile(source, 'private-build-resource-limits', 'exec')
        tree = ast.parse(source)
        constants = {n.targets[0].id: ast.literal_eval(n.value) for n in tree.body
            if isinstance(n, ast.Assign) and isinstance(n.targets[0], ast.Name)
            and n.targets[0].id in ('WATCHDOG_TOKEN', 'WATCHDOG_PARENT_PID', 'WATCHDOG_PROOF_FD', 'WATCHDOG_DEADLINE_MONOTONIC')}
        fn = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == 'supervise_watchdog')
        nodes = list(ast.walk(fn))
        assign = next(n for n in nodes if isinstance(n, ast.Assign) and isinstance(n.targets[0], ast.Name) and n.targets[0].id == 'env')
        update = next(n for n in nodes if isinstance(n, ast.Expr) and isinstance(n.value, ast.Call)
            and isinstance(n.value.func, ast.Attribute) and isinstance(n.value.func.value, ast.Name)
            and n.value.func.value.id == 'env' and n.value.func.attr == 'update')
        scope = dict(constants, os=cache.os, token='unit-token', proof_read=9, started=100, wall_seconds=120)
        key = constants['WATCHDOG_DEADLINE_MONOTONIC']
        with mock.patch.dict(cache.os.environ, {key: '999'}, clear=True), mock.patch.object(cache.os, 'getpid', return_value=42):
            exec(compile(ast.fix_missing_locations(ast.Module(body=[assign, update], type_ignores=[])), 'actual-watchdog-environment', 'exec'), scope)
        self.assertEqual(scope['env'][key], '220')
        self.assertEqual(scope['env'][constants['WATCHDOG_PARENT_PID']], '42')
        self.assertEqual(scope['env'][constants['WATCHDOG_PROOF_FD']], '9')
        self.assertEqual(scope['env'][constants['WATCHDOG_TOKEN']], 'unit-token')

    def native_probe(self):
        from types import SimpleNamespace
        return [SimpleNamespace(stdout='x86_64-linux-gnu\n'),
                SimpleNamespace(stdout='clang fixture\n'),
                SimpleNamespace(stderr='"-target-cpu" "fixture-cpu" "-target-feature" "+sse2" "-target-feature" "-avx512f"')]

    def clang(self, responses, *, deadline=None, clock=None):
        import contextlib
        stack = contextlib.ExitStack()
        self.addCleanup(stack.close)
        stack.enter_context(mock.patch.dict(cache.os.environ,
            {} if deadline is None else {'WIKIDICT_BUILD_DEADLINE_MONOTONIC': deadline}, clear=True))
        if clock is not None:
            stack.enter_context(mock.patch.object(cache.time, 'monotonic', side_effect=clock))
        stack.enter_context(mock.patch.object(cache.shutil, 'which', return_value='/clang'))
        stack.enter_context(mock.patch.object(cache.Path, 'resolve', return_value=Path('/clang')))
        stack.enter_context(mock.patch.object(cache, 'tool_identity', return_value={'unchanged': 'tool-and-libraries'}))
        return stack.enter_context(mock.patch.object(cache.subprocess, 'run', side_effect=responses))

    def test_identity_probe_uses_decreasing_real_job_budget_without_changing_identity(self):
        run = self.clang(self.native_probe(), deadline='300', clock=[100, 110, 130])
        observed = cache.clang_identity('clang', ['-march=native'])
        self.assertEqual([c.kwargs['timeout'] for c in run.call_args_list], [200, 190, 170])
        self.assertTrue(all(c.kwargs['check'] for c in run.call_args_list))
        self.assertEqual(observed, {'tool': {'unchanged': 'tool-and-libraries'},
            'target': 'x86_64-linux-gnu', 'version': 'clang fixture',
            'resolved_native': {'cpu': 'fixture-cpu', 'features': ['+sse2', '-avx512f']}})
        self.assertEqual(run.call_args.args[0], ['/clang', '-###', '-march=native', '-x', 'c', '-c', '/dev/null', '-o', '/dev/null'])

    def test_standalone_identity_probe_keeps_original_timeout_and_schema(self):
        run = self.clang(self.native_probe())
        observed = cache.clang_identity('clang', ['-march=native'])
        self.assertEqual([c.kwargs['timeout'] for c in run.call_args_list], [15, 15, 15])
        self.assertEqual(set(observed), {'tool', 'target', 'version', 'resolved_native'})

    def test_expired_or_malformed_deadline_refuses_before_probe(self):
        for raw in ('100', '99', 'nan', 'inf', '-inf', 'not-a-number', str(100 + 7*24*60*60 + 1)):
            with self.subTest(deadline=raw), mock.patch.dict(cache.os.environ, {'WIKIDICT_BUILD_DEADLINE_MONOTONIC': raw}), mock.patch.object(cache.time, 'monotonic', return_value=100), mock.patch.object(cache.shutil, 'which', return_value='/clang'), mock.patch.object(cache.Path, 'resolve', return_value=Path('/clang')), mock.patch.object(cache.subprocess, 'run') as run:
                with self.assertRaises(ValueError):
                    cache.clang_identity('clang', ['-march=native'])
                run.assert_not_called()

    def test_probe_timeout_and_real_tool_failure_propagate_without_retry(self):
        for error in (cache.subprocess.TimeoutExpired(['/clang'], 40), cache.subprocess.CalledProcessError(1, ['/clang'])):
            with self.subTest(error=type(error).__name__):
                run = self.clang(error, deadline='200', clock=[100])
                with self.assertRaises(type(error)):
                    cache.clang_identity('clang', ['-march=native'])
                self.assertEqual(run.call_count, 1)

    def test_missing_tool_remains_fatal_without_generic_target(self):
        with mock.patch.object(cache.shutil, 'which', return_value=None), mock.patch.object(cache.subprocess, 'run') as run:
            with self.assertRaisesRegex(ValueError, 'Clang executable unavailable'):
                cache.clang_identity('missing', ['-march=native'])
            run.assert_not_called()

    def test_malformed_native_features_remain_fatal(self):
        responses = self.native_probe()
        responses[-1].stderr = '"-target-cpu" "fixture-cpu"'
        run = self.clang(responses, deadline='200', clock=[100, 101, 102])
        with self.assertRaisesRegex(ValueError, 'Clang native CPU/features unavailable'):
            cache.clang_identity('clang', ['-march=native'])
        self.assertEqual(run.call_count, 3)




class ExtractionCachePhaseTest(unittest.TestCase):
    def invoke_entry(self, action, outcome, *, broken_log=False):
        import ast
        import io
        import types
        entry = next(node for node in ast.parse(Path(cache.__file__).read_text()).body
                     if isinstance(node, ast.If) and ast.unparse(node.test) == "__name__ == '__main__'")
        stderr = io.StringIO()
        calls = []
        def main(argv):
            calls.append(list(argv))
            if isinstance(outcome, BaseException): raise outcome
            return outcome
        fake_sys = types.SimpleNamespace(argv=['extraction_cache.py', action], stderr=stderr,
                                        exit=lambda code: (_ for _ in ()).throw(SystemExit(code)))
        namespace = dict(__name__='__main__', main=main, sys=fake_sys,
                         time=types.SimpleNamespace(monotonic=mock.Mock(side_effect=[10.0, 12.125])),
                         json=json, subprocess=cache.subprocess)
        if broken_log:
            def print_broken(*args, **kwargs): raise OSError('diagnostic unavailable')
            namespace['print'] = print_broken
        with self.assertRaises(SystemExit) as exited:
            exec(compile(ast.Module(body=[entry], type_ignores=[]), cache.__file__, 'exec'), namespace)
        self.assertEqual([['extraction_cache.py', action]], calls)
        return exited.exception.code, stderr.getvalue()

    def test_cache_cli_timing_preserves_success_and_cache_miss_codes(self):
        for action, result in [('probe', 3), ('publish', 0), ('probe-objects', 0), ('publish-objects', 0)]:
            code, output = self.invoke_entry(action, result)
            self.assertEqual(result, code)
            records = [json.loads(line[len('EXTRACTION_CACHE_PHASE '):]) for line in output.splitlines()]
            self.assertEqual([dict(action=action, status='returned', exit_code=result,
                                   seconds=2.125, scope='joined-helper-invocation-wall')], records)

    def test_cache_cli_timing_retains_probe_failure_and_original_diagnostic(self):
        failure = cache.subprocess.TimeoutExpired(['clang', '-###'], 15)
        code, output = self.invoke_entry('probe-objects', failure)
        self.assertEqual(1, code)
        self.assertIn('extraction cache: ', output)
        record = json.loads(output.split('EXTRACTION_CACHE_PHASE ', 1)[1])
        self.assertEqual(('failure', 1, 2.125), (record['status'], record['exit_code'], record['seconds']))

    def test_cache_cli_timing_output_failure_preserves_original_return(self):
        code, _ = self.invoke_entry('probe', 3, broken_log=True)
        self.assertEqual(3, code)




class OptionalExtractionPhaseTimingTests(unittest.TestCase):
    def exercise(self, enabled, *, failure=None, unavailable_cpu=False, broken_emit=False):
        import contextlib
        import io
        fixture = ExtractionCacheTest('test_snapshot_main_cold_publish_warm_link_and_copy')
        fixture.setUp(); self.addCleanup(fixture.doCleanups)
        stderr, stdout = io.StringIO(), io.StringIO()
        clock = mock.Mock(side_effect=OSError('no thread clock')) if unavailable_cpu else cache.time.thread_time
        emit = mock.Mock(side_effect=OSError('diagnostic unavailable')) if broken_emit else cache._cache_phase_event
        completion = mock.Mock(side_effect=failure) if failure else cache.validate_extraction_completion
        result, caught = None, None
        with mock.patch.dict(cache.os.environ, {cache.PHASE_TIMING_ENV: '1' if enabled else '0'}), \
             mock.patch.object(cache.time, 'thread_time', clock), \
             mock.patch.object(cache, '_cache_phase_event', emit), \
             mock.patch.object(cache, 'validate_extraction_completion', completion), \
             mock.patch.object(cache, 'walk_assets', wraps=cache.walk_assets) as walks, \
             mock.patch.object(cache, 'sha256', wraps=cache.sha256) as hashes, \
             contextlib.redirect_stderr(stderr), contextlib.redirect_stdout(stdout):
            try: result = cache.publish(fixture.root, fixture.expected, fixture.source)
            except Exception as error: caught = error
        records = [json.loads(line.split(' ', 1)[1]) for line in stderr.getvalue().splitlines()]
        markers = list(fixture.root.glob('*/.complete.json')) if fixture.root.exists() else []
        marker = markers[0].read_bytes() if markers else None
        self.assertEqual((fixture.source/'modules/123.lua').read_text(), 'return 1')
        return result, caught, records, marker, (walks.call_count, hashes.call_count)

    def test_opt_in_preserves_bytes_returns_and_number_of_walks_and_hashes(self):
        off = self.exercise(False); on = self.exercise(True)
        self.assertEqual((off[0], on[0]), (0, 0)); self.assertIsNone(off[1]); self.assertIsNone(on[1])
        self.assertEqual(off[3], on[3]); self.assertEqual(off[4], on[4]); self.assertEqual(off[2], [])
        self.assertEqual({row['phase'] for row in on[2]}, {'setup', 'preflight', 'completion', 'destination_selection', 'link_copy', 'record_assets_hash', 'seal_cleanup', 'prune'})
        hashed = next(row for row in on[2] if row['phase']=='record_assets_hash')
        self.assertEqual(hashed['files'], len(cache.FILES)+1)
        self.assertGreater(hashed['bytes'], 0); self.assertTrue(all(row['status']=='success' for row in on[2]))

    def test_disabled_has_no_clock_and_logging_failure_never_replaces_original(self):
        with mock.patch.object(cache.time, 'monotonic', side_effect=AssertionError('disabled clock')):
            self.assertEqual(self.exercise(False)[0], 0)
        failure = ValueError('original completion failure')
        off = self.exercise(False, failure=failure); on = self.exercise(True, failure=failure, broken_emit=True)
        self.assertIs(off[1], failure); self.assertIs(on[1], failure); self.assertEqual(off[4], on[4])
        self.assertIsNone(off[3]); self.assertIsNone(on[3]); self.assertEqual(self.exercise(True, broken_emit=True)[0], 0)

    def test_failed_phase_and_unavailable_thread_clock_are_explicit(self):
        failure = ValueError('original completion failure')
        row = self.exercise(True, failure=failure)
        self.assertIs(row[1], failure); self.assertEqual(row[2][-1]['phase'], 'completion'); self.assertEqual(row[2][-1]['status'], 'failure')
        result = self.exercise(True, unavailable_cpu=True)
        self.assertEqual(result[0], 0)
        self.assertTrue(all(x['thread_cpu_seconds'] is None and x['thread_cpu_available'] is False for x in result[2]))


class CurrentCompilerLayoutTests(unittest.TestCase):
    setUp = CompletedExpanderTests.setUp

    def test_relocated_policy_and_abi_preserve_semantic_labels_and_ignore_old_tree(self):
        original, stamps = cache.completed_producer_identity(self.graph)
        compiler = self.project / 'compiler'; compiler.mkdir()
        for name in ('tools', 'src'):
            (self.project / name).rename(compiler / name)
        current, current_stamps = cache.completed_producer_identity(self.graph)
        self.assertEqual(current, original)
        self.assertEqual(current_stamps, stamps)
        self.assertEqual([row[0] for row in current['abi']], list(cache.ABI_FILES))
        self.assertEqual([row[0] for row in current['policy']], ['build.zig', *cache.PIPELINE_POLICY_FILES])
        for name in (*cache.ABI_FILES, *cache.PIPELINE_POLICY_FILES):
            old = self.project / name; old.parent.mkdir(parents=True, exist_ok=True)
            old.write_bytes(b'unselected retained tree')
        self.assertEqual(cache.completed_producer_identity(self.graph)[0], original)
        selected = compiler / cache.ABI_FILES[0]
        selected.write_bytes(b'changed current ABI')
        self.assertNotEqual(cache.completed_producer_identity(self.graph)[0]['abi'], original['abi'])


class SealedFrontendTests(unittest.TestCase):
    # Reuse the existing real-file/object-cache fixture and its native-observer
    # mocks. No compiler, link process, expander, or presentation oracle runs.
    setUp = CompletedExpanderTests.setUp
    fixture = CompletedExpanderTests.fixture
    call = CompletedExpanderTests.call

    @staticmethod
    def reference(path):
        raw = path.read_bytes()
        return dict(path=str(path), bytes=len(raw), sha256=cache.hashlib.sha256(raw).hexdigest())

    def write_json(self, path, value):
        path.write_text(json.dumps(value))
        return self.reference(path)

    def prepared(self):
        if self.root.exists(): cache.shutil.rmtree(self.root)
        root, dump, snapshots = self.fixture(ready=False,
            output=self.base / ('old-workspace-' + str(self.sequence + 1)) / 'expander')
        self.assertEqual(0, self.call('seal-expander', root, dump, snapshots,
                                     dump_sha=cache.sha256(dump)))
        cache.shutil.rmtree(root / 'llvm')
        (root / '.incomplete').unlink(); (root.parent / '.incomplete').write_bytes(b'expander ready')
        seal = cache.read_marker(root / cache.COMPLETED_EXPANDER)
        dependencies = {}
        for field, name in (('extractor','modules'),('llvm','llvm'),('runtime','worker_object'),
                            ('leaf','value_leaf_bc'),('main_c','worker_main_c'),('zig','zig'),('clang','clang')):
            dependencies[name] = self.reference(Path(self.graph[field]))
        for name in ('build.zig','tools/bundle_build.zig','tools/extraction_cache.py', *cache.ABI_FILES):
            dependencies['runtime_source:' + name] = self.reference(self.project / name)
        dependencies['extraction_helper'] = self.reference(self.project / 'tools/extraction_cache.py')
        builder = self.project / 'tools/build_wiktionaries.py'; builder.write_bytes(b'fixture caller')
        roles = {'dict-bundle-build': dict(dependencies=dependencies, zig_sha256='e' * 64)}
        old_roles = self.write_json(self.base / 'old-roles.json', roles)
        current_roles = self.write_json(self.base / 'current-roles.json', roles)
        old_workspace = root.parent.parent
        old_plan = dict(roles=old_roles, inputs=[self.reference(dump)], dump=self.reference(dump),
            workspace=str(old_workspace), cache=dict(path=str(self.root), device=self.root.stat().st_dev,
                inode=self.root.stat().st_ino, mode=self.root.stat().st_mode & 0o7777, uid=self.root.stat().st_uid),
            expander_args=[str(dump), str(root.parent), '--expander-only', '--seal-prepared-source',
                '--verified-dump-sha256', cache.sha256(dump), '--verified-index-sha256', 'b' * 64])
        plan_ref = self.write_json(self.base / 'old-plan.json', old_plan)
        result = dict(passed=True, source_after=True, inputs_after=True, pages_executed=0,
            input_authority=plan_ref, role_map=old_roles, expander=str(root),
            worker=self.reference(root / 'dict-bundle-expander'), metadata=self.reference(root / 'lua-program.meta'),
            source_receipt=self.reference(root / 'extraction-source.json'),
            completed_expander_seal=self.reference(root / cache.COMPLETED_EXPANDER))
        result_ref = self.write_json(self.base / 'old-result.json', result)
        closure = dict(outcome='PASSED-PHYSICALLY-SOURCE-CLOSED', source_after=True,
            allocation_released=True, pages_executed=0,
            **{name: result[name] for name in ('worker','metadata','source_receipt')})
        closure_ref = self.write_json(self.base / 'old-closure.json', closure)
        data = dict(old_plan, roles=current_roles, workspace=str(self.base / ('new-workspace-' + str(self.sequence))),
                    builder=self.reference(builder))
        data['expander_args'] = list(old_plan['expander_args']); data['expander_args'][1] = data['workspace'] + '/expander'
        data['sealed_frontend'] = dict(version=1, preparation_result=result_ref, preparation_closure=closure_ref,
            original_policy_git=dict(repository=str(self.project), commit='1' * 40), layout_sources=[])
        data_path = self.base / 'current-data.json'; reference = self.write_json(data_path, data)
        return root, dump, snapshots, seal, data_path, data, reference

    def selected(self, reference):
        # Native qualification/Git is already exercised by the unchanged caller's
        # constructor. These pure controls cover every new input/graph comparison;
        # the eventual actual retained-role benchmark must execute validate_roles=True.
        with mock.patch.object(cache, '__file__', str(self.project / 'tools/extraction_cache.py')):
            return cache._frontend_selection(reference, self.graph, validate_roles=False)

    def test_frontend_reference_and_data_refuse_mutation_without_new_manifest(self):
        root, dump, snapshots, seal, path, data, reference = self.prepared()
        self.selected(reference)
        path.write_text(path.read_text() + ' ')
        with self.assertRaises(ValueError): self.selected(reference)
        reference = self.reference(path)
        data['inputs'] = []
        reference = self.write_json(path, data)
        with self.assertRaisesRegex(ValueError, 'ordinary input'): self.selected(reference)
        data['inputs'] = [self.reference(dump)]; data['expander_args'][-1] = 'c' * 64
        reference = self.write_json(path, data)
        with self.assertRaisesRegex(ValueError, 'arguments'): self.selected(reference)
        self.assertEqual(b'linked worker', (root / 'dict-bundle-expander').read_bytes())

    def test_frontend_selection_refuses_graph_abi_policy_and_missing_layout_authority(self):
        import copy
        root, dump, snapshots, seal, path, data, reference = self.prepared()
        current_path = Path(data['roles']['path']); original = cache.read_marker(current_path)
        for name in ('modules', 'llvm', 'value_leaf_bc', 'worker_main_c', 'zig',
                     'runtime_source:src/lua/program_metadata.zig'):
            with self.subTest(dependency=name):
                changed = copy.deepcopy(original); changed['dict-bundle-build']['dependencies'][name]['sha256'] = 'd' * 64
                data['roles'] = self.write_json(current_path, changed); reference = self.write_json(path, data)
                with self.assertRaisesRegex(ValueError, 'dependency'): self.selected(reference)
        data['roles'] = self.write_json(current_path, original)
        abi_path = self.project / cache.ABI_FILES[0]; original_abi = abi_path.read_bytes()
        abi_path.write_bytes(b'changed live ABI declaration')
        reference = self.write_json(path, data)
        with self.assertRaisesRegex(ValueError, 'ABI'): self.selected(reference)
        abi_path.write_bytes(original_abi)
        runtime = Path(self.graph['runtime']); runtime.write_bytes(b'qualified different runtime fixture')
        changed = copy.deepcopy(original); changed['dict-bundle-build']['dependencies']['worker_object'] = self.reference(runtime)
        data['roles'] = self.write_json(current_path, changed); reference = self.write_json(path, data)
        with self.assertRaisesRegex(ValueError, 'layout authority'): self.selected(reference)
        proof = self.write_json(self.base / 'layout-source.json', {'fixture_source_contract': 'unchanged layouts'})
        changed['dict-bundle-build']['layout_source_correspondence'] = proof
        data['sealed_frontend']['layout_sources'] = [proof]
        data['roles'] = self.write_json(current_path, changed); reference = self.write_json(path, data)
        self.selected(reference)
        Path(proof['path']).write_text('{}')
        with self.assertRaises(ValueError): self.selected(reference)
        data['sealed_frontend']['layout_sources'] = []
        runtime.write_bytes(b'runtime'); data['roles'] = self.write_json(current_path, original)
        helper = self.project / 'tools/extraction_cache.py'; helper.write_bytes(b'mutated live helper')
        reference = self.write_json(path, data)
        with self.assertRaisesRegex(ValueError, 'live policy'): self.selected(reference)

    def test_frontend_transition_and_identity_keep_all_nonruntime_semantics(self):
        import copy
        root, dump, snapshots, seal, path, data, reference = self.prepared()
        original = seal['identity']; current = copy.deepcopy(original)
        current['producer']['runtime'] = [100, 'c' * 64]
        current['producer']['policy'][1][1] = [200, 'd' * 64]
        current['producer']['policy'][2][1] = [300, 'e' * 64]
        cache._frontend_producer_transition(original['producer'], current['producer'])
        bad_policy = copy.deepcopy(current['producer']); bad_policy['policy'][0][1] = [999, 'f' * 64]
        with self.assertRaises(ValueError): cache._frontend_producer_transition(original['producer'], bad_policy)
        for name in ('llvm','leaf','main_c','zig','clang','unicode','abi','link_flags'):
            with self.subTest(producer=name):
                bad = copy.deepcopy(current['producer']); bad[name] = {'changed': True}
                with self.assertRaises(ValueError): cache._frontend_producer_transition(original['producer'], bad)
        for name in ('source','providers','verified_input','plans','version'):
            with self.subTest(identity=name):
                bad = copy.deepcopy(current); bad[name] = {'changed': True}
                with self.assertRaises(ValueError): cache._frontend_identity_matches(original, bad)
        cache._frontend_identity_matches(original, current)
        for name in ('lua-program.meta','page-index.tsv','modules/123.lua'):
            bad = copy.deepcopy(current)
            next(row for row in bad['assets'] if row[0] == name)[2] = 'f' * 64
            with self.assertRaises(ValueError): cache._frontend_identity_matches(original, bad)

    def test_frontend_objects_verify_every_key_digest_order_and_abi_before_staging(self):
        import copy
        root, dump, snapshots, seal, path, data, reference = self.prepared()
        for changed in ('order', 'abi', 'payload', 'missing'):
            with self.subTest(changed=changed):
                llvm = self.base / ('restore-' + changed); llvm.mkdir()
                snapshot = copy.deepcopy(seal['link']['object_inputs']); ordered = copy.deepcopy(seal['link']['ordered_objects'])
                first_name, first_identity = next(cache.object_entries(snapshot['identity']))
                source = cache.object_cache_path(self.root, first_identity) / 'object.o'
                original = source.read_bytes()
                if changed == 'order': ordered.reverse()
                elif changed == 'abi': snapshot['provenance']['abi'][0][1] = [1, 'a' * 64]
                elif changed == 'payload': source.write_bytes(b'corrupt object')
                else: source.unlink()
                with self.assertRaises(ValueError):
                    cache._restore_frontend_objects(self.root, llvm, snapshot, ordered, self.project, reference)
                self.assertFalse((llvm / '.object-identity.json').exists())
                self.assertFalse((llvm / '.object-hits').exists())
                source.write_bytes(original)
        llvm = self.base / 'restore-success'; llvm.mkdir()
        cache._restore_frontend_objects(self.root, llvm, seal['link']['object_inputs'], seal['link']['ordered_objects'], self.project, reference)
        self.assertEqual('1' * len(seal['link']['ordered_objects']) + '\n', (llvm / '.object-hits').read_text())
        self.assertEqual(reference, cache.read_marker(llvm / '.object-identity.json')['provenance']['frontend_reference'])
        for name, size, digest in seal['link']['ordered_objects']:
            self.assertEqual([size, digest], cache.stable_file_digest(llvm / name))
        self.assertFalse(any(llvm.glob('*.bc')))

    def test_frontend_probe_runs_real_extraction_validation_once_then_reuses_metadata(self):
        root, dump, snapshots, seal, path, data, reference = self.prepared()
        expected = cache._frontend_extraction_identity(self.graph['extractor'], cache.sha256(dump), 'b' * 64, root)
        self.assertEqual(0, cache.publish(self.root, expected, root))
        output = Path(data['workspace']) / 'expander' / '.bundle-expander'; (output / 'llvm').mkdir(parents=True)
        for name, source in snapshots.items():
            if source is not None: (output / name).symlink_to(source)
        cache.shutil.copyfile(self.graph['leaf'], output / 'llvm/value_leaf.bc')
        real_selection = cache._frontend_selection
        def eligibility(ref, graph, **kwargs):
            with mock.patch.object(cache, '__file__', str(self.project / 'tools/extraction_cache.py')):
                return real_selection(ref, graph, validate_roles=False)
        old_worker = (root / 'dict-bundle-expander').read_bytes()
        with mock.patch.object(cache, '_frontend_selection', side_effect=eligibility), \
             mock.patch.object(cache, 'validate', wraps=cache.validate) as validation:
            self.assertEqual(0, cache.probe_sealed_frontend(self.root, self.graph['extractor'], cache.sha256(dump),
                'b' * 64, output, dump, self.graph, reference))
        self.assertEqual(1, validation.call_count)
        self.assertEqual((root / 'lua-program.meta').read_bytes(), (output / 'llvm/program.meta').read_bytes())
        self.assertFalse((output / 'dict-bundle-expander').exists())
        self.assertFalse((output / cache.COMPLETED_EXPANDER).exists())
        self.assertFalse(any((output / 'llvm').glob('module_batch*.bc')))
        self.assertEqual(old_worker, (root / 'dict-bundle-expander').read_bytes())
        self.assertEqual(seal, cache.read_marker(root / cache.COMPLETED_EXPANDER))

    def test_frontend_probe_missing_cache_and_retargeted_provider_refuse_without_seal(self):
        root, dump, snapshots, seal, path, data, reference = self.prepared()
        output = Path(data['workspace']) / 'expander' / '.bundle-expander'; (output / 'llvm').mkdir(parents=True)
        for name, source in snapshots.items():
            if source is not None: (output / name).symlink_to(source)
        real_selection = cache._frontend_selection
        def eligibility(ref, graph, **kwargs):
            with mock.patch.object(cache, '__file__', str(self.project / 'tools/extraction_cache.py')):
                return real_selection(ref, graph, validate_roles=False)
        with mock.patch.object(cache, '_frontend_selection', side_effect=eligibility):
            with self.assertRaisesRegex(ValueError, 'extraction hit'):
                cache.probe_sealed_frontend(self.root, self.graph['extractor'], cache.sha256(dump), 'b' * 64,
                                           output, dump, self.graph, reference)
            target = self.base / 'other-provider'; target.write_bytes(Path(snapshots['interface-messages.tsv']).read_bytes())
            (output / 'interface-messages.tsv').unlink(); (output / 'interface-messages.tsv').symlink_to(target)
            with self.assertRaisesRegex(ValueError, 'physical input'):
                cache.probe_sealed_frontend(self.root, self.graph['extractor'], cache.sha256(dump), 'b' * 64,
                                           output, dump, self.graph, reference)
        self.assertFalse((output / cache.COMPLETED_EXPANDER).exists())
        self.assertFalse((output / 'llvm/program.meta').exists())


    def original_mixed_object_record(self):
        import copy
        root, dump, snapshots, seal, path, data, reference = self.prepared()
        entries = list(cache.object_entries(seal['link']['object_inputs']['identity']))
        self.assertGreaterEqual(len(entries), 2)
        first = cache.object_cache_path(self.root, entries[0][1]) / '.complete.json'
        marker = cache.read_marker(first)
        marker['provenance']['abi'][2][1] = '9' * 64
        self.write_json(first, marker)
        selected = data['sealed_frontend']; result = cache.read_marker(Path(selected['preparation_result']['path']))
        record = dict(preparation_result=selected['preparation_result'], closure=selected['preparation_closure'],
            role_map=result['role_map'], input_authority=result['input_authority'], new_seal=result['completed_expander_seal'],
            ordered_count=len(entries), ordered_identity_exact=True, ordered_object_digests_exact=True,
            all_marker_identities_and_abi_authenticated=True, pages_executed=0, rows=[])
        for index, ((name, identity), linked) in enumerate(zip(entries, seal['link']['ordered_objects'])):
            source = cache.object_cache_path(self.root, identity); stat = (source / 'object.o').stat()
            record['rows'].append(dict(ordinal=index, link_name=name, cache_key=source.name,
                marker=self.reference(source / '.complete.json'), object=linked[1:],
                object_stat=dict(dev=stat.st_dev, ino=stat.st_ino, mode=oct(stat.st_mode & 0o7777), bytes=stat.st_size),
                abi_provenance=cache.read_marker(source / '.complete.json')['provenance']['abi']))
        proof = self.base / 'original-object-correspondence.json'
        data['object_correspondence'] = self.write_json(proof, record)
        reference = self.write_json(path, data)
        return root, seal, path, data, reference, proof, record

    def test_frontend_original_mixed_marker_provenance_is_preserved_without_restamping(self):
        import copy
        root, seal, path, data, reference, proof, record = self.original_mixed_object_record()
        self.assertNotEqual(record['rows'][0]['abi_provenance'], seal['link']['object_inputs']['provenance']['abi'])
        before = {row['marker']['path']: Path(row['marker']['path']).read_bytes() for row in record['rows']}
        without = dict(data); del without['object_correspondence']
        strict = self.write_json(self.base / 'without-proof.json', without)
        failed = self.base / 'mixed-without-proof'; failed.mkdir()
        with self.assertRaises(ValueError):
            cache._restore_frontend_objects(self.root, failed, seal['link']['object_inputs'],
                seal['link']['ordered_objects'], self.project, strict)
        self.assertFalse((failed / '.object-identity.json').exists())
        output = self.base / 'mixed-preserved'; output.mkdir()
        cache._restore_frontend_objects(self.root, output, seal['link']['object_inputs'],
            seal['link']['ordered_objects'], self.project, reference)
        self.assertEqual('1' * len(record['rows']) + '\n', (output / '.object-hits').read_text())
        for row in record['rows']:
            self.assertEqual(before[row['marker']['path']], Path(row['marker']['path']).read_bytes())
            self.assertEqual(row['object'], cache.stable_file_digest(output / row['link_name']))
        bad_snapshot = copy.deepcopy(seal['link']['object_inputs']); bad_snapshot['provenance']['abi'][0][1] = '8' * 64
        target = self.base / 'mixed-current-abi-refused'; target.mkdir()
        with self.assertRaisesRegex(ValueError, 'ABI'):
            cache._restore_frontend_objects(self.root, target, bad_snapshot, seal['link']['ordered_objects'], self.project, reference)
        self.assertFalse((target / '.object-identity.json').exists())

    def test_frontend_original_object_proof_refuses_cross_preparation_and_marker_substitution(self):
        import copy
        root, seal, path, data, reference, proof, original = self.original_mixed_object_record()
        for kind in ('preparation', 'seal', 'input', 'key', 'order', 'digest', 'marker', 'provenance', 'inode', 'raw-marker', 'payload'):
            with self.subTest(kind=kind):
                record = copy.deepcopy(original)
                if kind == 'preparation': record['preparation_result']['sha256'] = '1' * 64
                elif kind == 'seal': record['new_seal']['sha256'] = '2' * 64
                elif kind == 'input': record['input_authority']['sha256'] = '3' * 64
                elif kind == 'key': record['rows'][0]['cache_key'] = '4' * 64
                elif kind == 'order': record['rows'].reverse()
                elif kind == 'digest': record['rows'][0]['object'][1] = '5' * 64
                elif kind == 'marker': record['rows'][0]['marker'] = record['rows'][1]['marker']
                elif kind == 'provenance': record['rows'][0]['abi_provenance'][2][1] = '6' * 64
                elif kind == 'inode': record['rows'][0]['object_stat']['ino'] += 1
                data['object_correspondence'] = self.write_json(proof, record)
                reference = self.write_json(path, data)
                marker = Path(original['rows'][0]['marker']['path']); raw = marker.read_bytes()
                entries = list(cache.object_entries(seal['link']['object_inputs']['identity']))
                payload = cache.object_cache_path(self.root, entries[0][1]) / 'object.o'; payload_bytes = payload.read_bytes()
                if kind == 'raw-marker': marker.write_bytes(raw + b' ')
                if kind == 'payload': payload.write_bytes(b'changed native object')
                target = self.base / ('mixed-refused-' + kind); target.mkdir()
                try:
                    with self.assertRaises(ValueError):
                        cache._restore_frontend_objects(self.root, target, seal['link']['object_inputs'],
                            seal['link']['ordered_objects'], self.project, reference)
                    self.assertFalse((target / '.object-identity.json').exists())
                    self.assertFalse((target / '.object-hits').exists())
                finally:
                    marker.write_bytes(raw); payload.write_bytes(payload_bytes)



    def test_frontend_nonempty_role_map_layout_authority_is_exact(self):
        root, dump, snapshots, seal, path, data, reference = self.prepared()
        roles_path = Path(data['roles']['path']); roles = cache.read_marker(roles_path)
        proof = self.write_json(self.base / 'actual-shaped-layout.json', {'unchanged_abi': True})
        roles['dict-bundle-build']['layout_source_correspondence'] = proof
        roles['dict-blob-build'] = {'layout_source_correspondence': proof}
        data['sealed_frontend']['layout_sources'] = [proof]
        data['roles'] = self.write_json(roles_path, roles)
        self.selected(self.write_json(path, data))
        other = self.write_json(self.base / 'other-layout.json', {'unchanged_abi': False})
        roles['dict-blob-build']['layout_source_correspondence'] = other
        data['roles'] = self.write_json(roles_path, roles)
        with self.assertRaisesRegex(ValueError, 'layout source authority'):
            self.selected(self.write_json(path, data))
        roles['dict-blob-build']['layout_source_correspondence'] = proof
        data['roles'] = self.write_json(roles_path, roles)
        data['sealed_frontend']['layout_sources'] = [other]
        with self.assertRaisesRegex(ValueError, 'layout source authority'):
            self.selected(self.write_json(path, data))

class DerivedProviderRestorationTests(unittest.TestCase):
    setUp = CompletedExpanderTests.setUp
    fixture = CompletedExpanderTests.fixture
    call = CompletedExpanderTests.call

    def restoration_fixture(self):
        root, dump, snapshots = self.fixture(ready=False)
        # Real EN dbed contains 61 empty Lua assets; frozen native assets permit zero bytes.
        (root / 'modules/empty.lua').write_bytes(b'')
        sources, old = {}, {}
        for name in cache.DERIVED_PROVIDER_FILES:
            payload = ('original selected ' + name + '\n').encode()
            original = self.base / ('missing-copy-' + str(self.sequence) + '-' + name)
            original.write_bytes(payload)
            source = self.base / ('retained-' + str(self.sequence) + '-' + name)
            source.write_bytes(payload)
            (root / name).symlink_to(original)
            snapshots[name] = str(original)
            sources[name] = dict(path=str(source), bytes=len(payload), sha256=cache.sha256(source))
            old[name] = original
        self.assertEqual(0, self.call('seal-expander', root, dump, snapshots))
        cache.shutil.rmtree(root / 'llvm')
        (root / '.incomplete').unlink(); (root.parent / '.incomplete').write_bytes(b'expander ready')
        raw = (root / cache.COMPLETED_EXPANDER).read_bytes()
        for path in old.values(): path.unlink()
        return root, dump, sources, raw

    def stage_restoration(self, root, sources):
        with (root / '.incomplete').open('xb') as stream: stream.write(cache.PROVIDER_UPDATE_MARKER)
        for name, descriptor in sources.items():
            (root / name).unlink(); (root / name).symlink_to(descriptor['path'])

    def test_restoration_preserves_original_native_and_source_bytes_without_copying(self):
        root, dump, sources, raw = self.restoration_fixture()
        original = cache.hashlib.sha256(raw).hexdigest()
        with self.assertRaises(ValueError): cache.frozen_runtime_context(root, dump, original)
        before = {name: (cache._full_stamp(Path(item['path']).stat()), Path(item['path']).stat().st_nlink)
                  for name, item in sources.items()}
        # Unrelated live policy evolution is not a new native emission.
        (self.project / 'tools/extraction_cache.py').write_bytes(b'new live helper policy')
        with mock.patch.object(cache, 'completed_producer_identity', side_effect=AssertionError('no native producer rebuild')):
            proof = cache.prepare_derived_provider_restoration(root, dump, original, sources)
            archive = Path(proof['original_seal_archive']['path'])
            self.assertEqual(raw, archive.read_bytes())
            self.stage_restoration(root, sources)
            successor = cache.finish_derived_provider_restoration(proof)
        after = cache.frozen_runtime_context(root, dump, successor, provider_update=True)
        previous = json.loads(raw)
        for name in ('identity', 'origin_graph', 'link'): self.assertEqual(previous[name], after[name])
        self.assertEqual('ordinary-derived-provider-restoration', after['provenance'])
        self.assertEqual(original, after['provider_update']['original_seal_sha256'])
        self.assertEqual(raw, archive.read_bytes())
        for name, item in sources.items():
            source = Path(item['path'])
            self.assertEqual(before[name], (cache._full_stamp(source.stat()), source.stat().st_nlink))
            self.assertEqual(str(source), cache.os.readlink(root / name))
            self.assertEqual(list(cache._full_stamp(source.stat())), after['runtime_stamps']['assets'][name])
        (root / '.incomplete').unlink()
        self.assertEqual(after, cache.frozen_runtime_context(root, dump, successor))
        with self.assertRaises(ValueError): cache.frozen_runtime_context(root, dump, original)

    def test_restoration_refuses_wrong_missing_or_changed_selected_sources(self):
        import copy
        for kind in ('content', 'missing', 'role', 'membership', 'after-prepare'):
            with self.subTest(kind=kind):
                root, dump, sources, raw = self.restoration_fixture()
                original = cache.hashlib.sha256(raw).hexdigest(); selected = copy.deepcopy(sources)
                name = sorted(sources)[0]
                if kind == 'content': Path(selected[name]['path']).write_bytes(b'wrong retained bytes')
                elif kind == 'missing': Path(selected[name]['path']).unlink()
                elif kind == 'role': selected[name] = selected[sorted(sources)[1]]
                elif kind == 'membership': selected.pop(name)
                if kind != 'after-prepare':
                    with self.assertRaises((ValueError, FileNotFoundError)):
                        cache.prepare_derived_provider_restoration(root, dump, original, selected)
                else:
                    proof = cache.prepare_derived_provider_restoration(root, dump, original, selected)
                    self.stage_restoration(root, selected)
                    Path(selected[name]['path']).write_bytes(b'changed after original authentication')
                    with self.assertRaises(ValueError): cache.finish_derived_provider_restoration(proof)
                self.assertEqual(raw, (root / cache.COMPLETED_EXPANDER).read_bytes())

    def test_restoration_refuses_native_alias_plan_source_and_archive_drift(self):
        for kind in ('worker', 'metadata', 'module', 'plan', 'dump', 'receipt', 'namespace', 'member', 'alias', 'library', 'archive'):
            with self.subTest(kind=kind):
                root, dump, sources, raw = self.restoration_fixture()
                proof = cache.prepare_derived_provider_restoration(root, dump, cache.hashlib.sha256(raw).hexdigest(), sources)
                self.stage_restoration(root, sources)
                if kind == 'alias':
                    name = sorted(sources)[0]; (root / name).unlink(); (root / name).symlink_to(sources[sorted(sources)[1]]['path'])
                else:
                    path = {'worker': root / 'dict-bundle-expander', 'metadata': root / 'lua-program.meta',
                            'module': root / 'modules/123.lua', 'plan': root.parent / 'compile-plan.tsv',
                            'dump': dump, 'receipt': root / 'extraction-source.json', 'namespace': root / 'namespace-registry.tsv',
                            'member': root / 'unknown-member', 'library': self.library,
                            'archive': Path(proof['original_seal_archive']['path'])}[kind]
                    path.write_bytes(b'changed selected input')
                with self.assertRaises(ValueError): cache.finish_derived_provider_restoration(proof)
                self.assertEqual(raw, (root / cache.COMPLETED_EXPANDER).read_bytes())

    def test_restoration_publication_failure_keeps_old_seal_and_incomplete_state(self):
        root, dump, sources, raw = self.restoration_fixture()
        original = cache.hashlib.sha256(raw).hexdigest()
        proof = cache.prepare_derived_provider_restoration(root, dump, original, sources)
        self.stage_restoration(root, sources)
        with mock.patch.object(cache, 'write_private_marker', side_effect=OSError('injected seal publication failure')):
            with self.assertRaises(OSError): cache.finish_derived_provider_restoration(proof)
        self.assertEqual(raw, (root / cache.COMPLETED_EXPANDER).read_bytes())
        self.assertEqual(cache.PROVIDER_UPDATE_MARKER, (root / '.incomplete').read_bytes())
        self.assertEqual(raw, Path(proof['original_seal_archive']['path']).read_bytes())
        self.assertFalse(list(root.parent.parent.glob('*.part-*')))




class MetadataCustodyRefreshTests(unittest.TestCase):
    setUp = CompletedExpanderTests.setUp
    fixture = CompletedExpanderTests.fixture
    call = CompletedExpanderTests.call
    binding = CompletedExpanderTests.binding

    def custody_fixture(self):
        root, dump, snapshots = self.fixture(ready=False)
        extra = self.base / ('figure-site-' + str(self.sequence)); extra.write_bytes(b'original figure site')
        snapshots['figure-siteinfo.raw.json'] = str(extra); (root / 'figure-siteinfo.raw.json').symlink_to(extra)
        self.call('seal-expander', root, dump, snapshots); cache.shutil.rmtree(root / 'llvm')
        (root / '.incomplete').unlink(); (root.parent / '.incomplete').write_bytes(b'expander ready')
        seal = self.binding(root); self.metadata_sequence = getattr(self, 'metadata_sequence', 0) + 1
        prefix = 'metadata-' + str(self.metadata_sequence) + '-'
        def write(name, value):
            p = self.base / (prefix + name); p.write_text(json.dumps(value)); return dict(path=str(p), bytes=p.stat().st_size, sha256=cache.sha256(p))
        def info(path):
            s = path.stat(); return {k:getattr(s,k) for k in ('st_dev','st_ino','st_mode','st_uid','st_gid','st_size','st_mtime_ns','st_ctime_ns','st_nlink')}
        source_manifest = write('manifest.json', {'original': True}); output_manifest = write('new-manifest.json', {'repaired': True})
        linked = []; target = self.base / (prefix + 'linked'); target.mkdir()
        names = ['figure-siteinfo.raw.json', 'interface-messages.tsv']
        for name in names:
            source = Path(snapshots[name]); before = info(source); digest = cache.sha256(source)
            cache.os.link(source, target / source.name)
            linked.append(dict(path=source.name, before=before, after=info(source), sha256_before=digest, sha256_after=cache.sha256(source)))
        observations = write('observations.json', dict(complete=True, source_content_mode_inode_preserved=True, linked_members=linked,
            source_manifest_sha256=source_manifest['sha256'], repair_manifest_sha256=source_manifest['sha256']))
        common = dict(outcome='PASSED-PHYSICALLY-SOURCE-CLOSED', source_after=True, source_lease_released=True, allocation_released=True)
        operation = write('operation.json', dict(common, observations=observations, linked_members=linked, source_manifest=source_manifest, output_manifest=output_manifest))
        result = write('native-result.json', dict(returncode=0, ordinary_full_stream_validation=True, input_after=True, pages_executed=0, compiler_executed=False,
            argv=['actual-qualified-test-fixture', '--check-figure-compatibility', '--full']))
        native = write('native-close.json', dict(common, native_returncode=0, ordinary_full_stream_validation=True, pages_executed=0, compiler_executed=False,
            repaired_manifest=output_manifest, compatibility=result))
        return root, dump, snapshots, dict(original_seal_sha256=seal, operation=operation, native_validation=native, names=names)

    def test_closed_multi_provider_custody_refresh_preserves_original_seal_and_logical_native_identity(self):
        root, dump, snapshots, receipt = self.custody_fixture(); seal = self.binding(root)
        raw = (root / cache.COMPLETED_EXPANDER).read_bytes(); original = cache.read_marker(root / cache.COMPLETED_EXPANDER)
        with self.assertRaises(ValueError): cache.frozen_runtime_context(root, dump, seal)
        selected = {Path(snapshots[name]) for name in receipt['names']}; observed = cache.stable_file_digest
        def no_rehash(path, **kwargs):
            self.assertNotIn(Path(path).resolve(), selected)
            return observed(path, **kwargs)
        with mock.patch.object(cache, 'stable_file_digest', side_effect=no_rehash):
            current = cache.frozen_runtime_context(root, dump, seal, metadata_custody_refresh=receipt)
        self.assertEqual(raw, (root / cache.COMPLETED_EXPANDER).read_bytes()); self.assertEqual(seal, self.binding(root))
        for name in ('identity', 'origin_graph', 'link', 'provenance'): self.assertEqual(original[name], current[name])
        self.assertEqual(original['runtime_stamps']['plans'], current['runtime_stamps']['plans'])
        self.assertEqual(original['runtime_stamps']['snapshot_links'], current['runtime_stamps']['snapshot_links'])
        for name, value in original['runtime_stamps']['assets'].items():
            self.assertEqual(list(cache._full_stamp((root / name).stat())) if name in receipt['names'] else value, current['runtime_stamps']['assets'][name])

    def test_metadata_custody_refuses_changed_bytes_inode_mode_mtime_nlink_and_unrecorded_alias(self):
        for change in ('bytes', 'inode', 'mode', 'mtime', 'nlink', 'alias'):
            with self.subTest(change=change):
                root, dump, snapshots, receipt = self.custody_fixture(); seal = self.binding(root); source = Path(snapshots[receipt['names'][0]]); before = source.stat()
                if change == 'bytes': source.write_bytes(b'x' * before.st_size); cache.os.utime(source, ns=(before.st_atime_ns, before.st_mtime_ns))
                elif change == 'inode':
                    other = source.with_suffix('.other'); other.write_bytes(source.read_bytes()); other.replace(source)
                elif change == 'mode': source.chmod(before.st_mode ^ 0o100)
                elif change == 'mtime': cache.os.utime(source, ns=(before.st_atime_ns, before.st_mtime_ns + 1))
                elif change == 'nlink': cache.os.link(source, source.with_suffix('.unexpected'))
                else:
                    alias = root / receipt['names'][0]; other = source.with_suffix('.same'); cache.os.link(source, other); alias.unlink(); alias.symlink_to(other)
                with self.assertRaises(ValueError): cache.frozen_runtime_context(root, dump, seal, metadata_custody_refresh=receipt)
                self.assertEqual(seal, self.binding(root))

    def test_metadata_custody_requires_exact_closed_operation_native_validation_and_selected_original_hashes(self):
        for change in ('bad-operation-hash', 'native-unrun', 'wrong-manifest', 'changed-digest', 'old-stamp', 'duplicate', 'unrecorded', 'native-asset'):
            with self.subTest(change=change):
                root, dump, snapshots, receipt = self.custody_fixture(); seal = self.binding(root)
                def rewrite(key, mutate):
                    p = Path(receipt[key]['path']); value = json.loads(p.read_text()); mutate(value); p.write_text(json.dumps(value)); receipt[key] = dict(path=str(p), bytes=p.stat().st_size, sha256=cache.sha256(p))
                if change == 'bad-operation-hash': receipt['operation']['sha256'] = '0' * 64
                elif change == 'native-unrun': rewrite('native_validation', lambda v:v.update(ordinary_full_stream_validation=False))
                elif change == 'wrong-manifest': rewrite('native_validation', lambda v:v.update(repaired_manifest={}))
                elif change in ('changed-digest', 'old-stamp'):
                    op = json.loads(Path(receipt['operation']['path']).read_text()); rows = op['linked_members']; rows[0]['sha256_after'] = '0' * 64 if change == 'changed-digest' else rows[0]['sha256_after']
                    if change == 'old-stamp': rows[0]['before']['st_ctime_ns'] += 1
                    obs_path = Path(op['observations']['path']); obs = json.loads(obs_path.read_text()); obs['linked_members'] = rows; obs_path.write_text(json.dumps(obs)); op['observations'] = dict(path=str(obs_path), bytes=obs_path.stat().st_size, sha256=cache.sha256(obs_path))
                    op_path = Path(receipt['operation']['path']); op_path.write_text(json.dumps(op)); receipt['operation'] = dict(path=str(op_path), bytes=op_path.stat().st_size, sha256=cache.sha256(op_path))
                elif change == 'duplicate': receipt['names'].append(receipt['names'][0])
                elif change == 'unrecorded': receipt['names'] = ['namespace-registry.tsv']
                else: receipt['names'] = ['dict-bundle-expander']
                with self.assertRaises(ValueError): cache.frozen_runtime_context(root, dump, seal, metadata_custody_refresh=receipt)
                self.assertEqual(seal, self.binding(root))

    def test_metadata_custody_brackets_source_and_native_assets_without_mixing_update_families(self):
        for change in ('source-during-validation', 'native-during-validation', 'mixed-update', 'mixed-book'):
            with self.subTest(change=change):
                root, dump, snapshots, receipt = self.custody_fixture(); seal = self.binding(root)
                if change in ('mixed-update', 'mixed-book'):
                    kwargs = dict(provider_update=True) if change == 'mixed-update' else dict(snapshot_metadata_refresh={})
                    with self.assertRaises(ValueError): cache.frozen_runtime_context(root, dump, seal, metadata_custody_refresh=receipt, **kwargs)
                    continue
                observed = cache.completed_source_binding
                def mutate_after_source(r, d):
                    value = observed(r, d)
                    target = Path(snapshots[receipt['names'][0]]) if change.startswith('source') else root / 'dict-bundle-expander'
                    info = target.stat(); target.write_bytes(target.read_bytes()); cache.os.utime(target, ns=(info.st_atime_ns, info.st_mtime_ns))
                    return value
                with mock.patch.object(cache, 'completed_source_binding', side_effect=mutate_after_source):
                    with self.assertRaises(ValueError): cache.frozen_runtime_context(root, dump, seal, metadata_custody_refresh=receipt)
                self.assertEqual(seal, self.binding(root))


    def test_metadata_custody_preserves_aliased_input_and_owns_changed_stamps(self):
        import copy
        root, dump, snapshots, receipt = self.custody_fixture(); seal = self.binding(root)
        original = cache.read_marker(root / cache.COMPLETED_EXPANDER)
        original['retained_stamp_alias'] = original['runtime_stamps']['assets']
        before = copy.deepcopy(original); receipt_before = copy.deepcopy(receipt)
        current = cache._closed_metadata_custody(root, original, seal, receipt)
        self.assertEqual(before, original); self.assertEqual(receipt_before, receipt)
        self.assertEqual(before['runtime_stamps']['assets'], current['retained_stamp_alias'])
        for name in receipt['names']:
            self.assertEqual(list(cache._full_stamp((root / name).stat())), current['runtime_stamps']['assets'][name])
        name = receipt['names'][0]
        current['runtime_stamps']['assets'][name][0] += 1
        current['runtime_stamps']['assets'].pop(receipt['names'][1])
        self.assertEqual(before, original); self.assertEqual(receipt_before, receipt)
        self.assertEqual(seal, self.binding(root))

    def test_frozen_context_parses_only_authenticated_bounded_bytes_and_checks_identity(self):
        import io
        for change in ('none', 'digest', 'different-first-read', 'identity', 'oversized'):
            with self.subTest(change=change):
                root, dump, snapshots, receipt = self.custody_fixture()
                marker = root / cache.COMPLETED_EXPANDER; record = cache.read_marker(marker)
                record['marker_note'] = 'trusted'; marker.write_text(json.dumps(record))
                seal = self.binding(root); receipt['original_seal_sha256'] = seal
                raw = marker.read_bytes(); physical = cache._full_stamp(marker.stat())
                forged = raw.replace(b'"trusted"', b'"forged!"', 1)
                self.assertNotEqual(raw, forged); self.assertEqual(len(raw), len(forged))
                opened = Path.open; reads = []
                class ChangedIdentity(io.BytesIO):
                    def __exit__(stream, *args):
                        result = super().__exit__(*args)
                        info = marker.stat(); cache.os.utime(marker, ns=(info.st_atime_ns, info.st_mtime_ns + 1))
                        return result
                def observed(path, *args, **kwargs):
                    if Path(path) == marker and args and args[0] == 'rb':
                        reads.append(True)
                        if len(reads) == 1 and change == 'different-first-read': return io.BytesIO(forged)
                        if len(reads) == 1 and change == 'identity': return ChangedIdentity(raw)
                    return opened(path, *args, **kwargs)
                maximum = len(raw) - 1 if change == 'oversized' else cache.MAX_MARKER_BYTES
                with mock.patch.object(Path, 'open', observed), mock.patch.object(cache, 'MAX_MARKER_BYTES', maximum):
                    if change == 'none':
                        current = cache.frozen_runtime_context(root, dump, seal, metadata_custody_refresh=receipt)
                        self.assertEqual('trusted', current['marker_note'])
                    else:
                        with self.assertRaises(ValueError):
                            cache.frozen_runtime_context(root, dump, '0' * 64 if change == 'digest' else seal, metadata_custody_refresh=receipt)
                self.assertEqual(raw, marker.read_bytes())
                if change != 'identity': self.assertEqual(physical, cache._full_stamp(marker.stat()))

    def test_metadata_custody_rejects_same_target_alias_change_during_validation(self):
        root, dump, snapshots, receipt = self.custody_fixture(); seal = self.binding(root)
        name = receipt['names'][0]; source = Path(snapshots[name]); before = cache._full_stamp(source.stat())
        alternate = source.with_name(source.name + '-alternate'); alternate.symlink_to(source)
        original = cache.completed_source_binding
        def change_alias(r, d):
            result = original(r, d)
            alias = root / name; alias.unlink(); alias.symlink_to(alternate)
            self.assertEqual(before, cache._full_stamp(source.stat()))
            return result
        with mock.patch.object(cache, 'completed_source_binding', side_effect=change_alias):
            with self.assertRaises(ValueError): cache.frozen_runtime_context(root, dump, seal, metadata_custody_refresh=receipt)
        self.assertEqual(seal, self.binding(root))


class FileMetadataProviderUpdateTests(unittest.TestCase):
    setUp = CompletedExpanderTests.setUp
    fixture = CompletedExpanderTests.fixture
    call = CompletedExpanderTests.call
    binding = CompletedExpanderTests.binding

    def file_fixture(self, *, book=False):
        self.zig_tool['tool_sha256'] = cache.sha256(Path(self.graph['zig']))
        self.tool['tool'] = cache.tool_identity(Path(self.graph['clang']))
        root, dump, snapshots = self.fixture(ready=False)
        original = self.base / ('file-origin-' + str(self.sequence))
        original.write_bytes(b'# wikidict-file-metadata-v2\nFile:Existing.png\t1\t10\t20\tBITMAP\tFile:Existing.png\n')
        snapshots['file-metadata.tsv'] = str(original)
        (root / 'file-metadata.tsv').symlink_to(original)
        for name in cache.DERIVED_PROVIDER_FILES:
            source = self.base / (str(self.sequence) + '-' + name)
            source.write_bytes(('original ' + name).encode())
            snapshots[name] = str(source); (root / name).symlink_to(source)
        if book:
            observed = self.base / ('observed-' + str(self.sequence)); observed.write_bytes(b'original Book bytes')
            snapshots['figure-page-observations.json'] = str(observed); (root / 'figure-page-observations.json').symlink_to(observed)
        self.call('seal-expander', root, dump, snapshots)
        cache.shutil.rmtree(root / 'llvm')
        (root / '.incomplete').unlink(); (root.parent / '.incomplete').write_bytes(b'expander ready')
        return root, dump, snapshots, original

    def source(self, root, raw=None, suffix='selected'):
        target = self.base / (str(self.sequence) + '-' + suffix)
        original = (root / 'file-metadata.tsv').read_bytes()
        target.write_bytes(raw if raw is not None else original + b'File:Voice.ogg\t1\t0\t0\tAUDIO\tFile:Actual.oga\n')
        return dict(path=str(target), bytes=target.stat().st_size, sha256=cache.sha256(target))

    def prepare_file(self, root, dump, source, titles=None):
        return cache.prepare_wikibase_provider_update(root, dump, self.binding(root),
            file_metadata_source=source,
            file_metadata_titles=['File:Voice.ogg'] if titles is None else titles)

    def stage_file(self, root, source):
        (root / '.incomplete').write_bytes(cache.FILE_METADATA_UPDATE_MARKER)
        temporary = root / '.file-metadata-update.part'
        temporary.symlink_to(source['path']); temporary.replace(root / 'file-metadata.tsv')
        return {'file-metadata.tsv': source['sha256']}

    def test_audio_append_original_clang_symlink_is_resolved_and_chain_and_target_drift_refused(self):
        for change in ('allowed', 'chain', 'target', 'publication-chain', 'locator-shape'):
            with self.subTest(change=change):
                root, dump, snapshots, original = self.file_fixture()
                target = Path(self.graph['clang']); alias = target.with_name('clang-alias-' + str(self.sequence))
                alias.symlink_to(target); record = cache.read_marker(root / cache.COMPLETED_EXPANDER)
                record['origin_graph']['clang'] = str(alias)
                cache.write_private_marker(root / cache.COMPLETED_EXPANDER, record)
                seal = self.binding(root); source = self.source(root); observed = cache.tool_identity
                def regular_tool(path):
                    self.assertFalse(Path(path).is_symlink())
                    return observed(path)
                with mock.patch.object(cache, 'tool_identity', side_effect=regular_tool):
                    proof = self.prepare_file(root, dump, source)
                    locator = proof['file_metadata_update']['native_clang_locator']
                    self.assertEqual(str(target), locator['resolved']); self.assertEqual(str(alias), locator['located'])
                    self.assertEqual(str(alias), locator['chain'][0]['path'])
                    hashes = self.stage_file(root, source)
                    if change == 'chain': alias.unlink(); alias.symlink_to(target)
                    elif change == 'target': target.write_bytes(b'other clang executable')
                    elif change == 'locator-shape': proof['file_metadata_update']['native_clang_locator'] = {'invalid': True}
                    if change == 'publication-chain':
                        real_write = cache.write_private_marker
                        def replace_alias_after_write(path, value):
                            real_write(path, value); alias.unlink(); alias.symlink_to(target)
                        with mock.patch.object(cache, 'write_private_marker', side_effect=replace_alias_after_write):
                            with self.assertRaises(ValueError): cache.finish_wikibase_provider_update(proof, hashes)
                        self.assertTrue((root / '.incomplete').exists()); continue
                    if change != 'allowed':
                        with self.assertRaises(ValueError): cache.finish_wikibase_provider_update(proof, hashes)
                        self.assertEqual(seal, self.binding(root)); continue
                    current = cache.finish_wikibase_provider_update(proof, hashes)
                (root / '.incomplete').unlink(); after = cache.frozen_runtime_context(root, dump, current)
                self.assertEqual(record['identity']['producer'], after['identity']['producer'])
                self.assertEqual(record['origin_graph'], after['origin_graph'])

    def test_audio_append_explicit_book_ctime_refresh_keeps_native_and_refuses_other_identity_changes(self):
        import stat
        for change in ('allowed', 'omitted', 'content', 'inode', 'mode', 'mtime', 'alias', 'nlink-during-validation'):
            with self.subTest(change=change):
                root, dump, snapshots, original = self.file_fixture(book=True)
                seal = self.binding(root); record = cache.read_marker(root / cache.COMPLETED_EXPANDER)
                target = Path(snapshots['figure-page-observations.json']); before = target.stat()
                target.chmod(stat.S_IMODE(before.st_mode) ^ 0o100); target.chmod(stat.S_IMODE(before.st_mode))
                receipt = dict(name='figure-page-observations.json', source=str(target), original_seal_sha256=seal,
                    old_stamp=record['runtime_stamps']['assets']['figure-page-observations.json'],
                    current_stamp=list(cache._full_stamp(target.stat())), current_nlink=target.stat().st_nlink, ctime_cause='unknown')
                source = self.source(root)
                if change == 'content':
                    self.assertEqual(len(target.read_bytes()), len(b'changed Book bytes!'))
                    target.write_bytes(b'changed Book bytes!'); cache.os.utime(target, ns=(before.st_atime_ns, before.st_mtime_ns))
                    receipt['current_stamp'] = list(cache._full_stamp(target.stat()))
                elif change == 'inode':
                    replacement = target.with_suffix('.new'); replacement.write_bytes(target.read_bytes()); replacement.replace(target)
                elif change == 'mode': target.chmod(stat.S_IMODE(before.st_mode) ^ 0o100)
                elif change == 'mtime': cache.os.utime(target, ns=(before.st_atime_ns, before.st_mtime_ns + 1))
                elif change == 'alias':
                    path = root / 'figure-page-observations.json'; path.unlink(); path.symlink_to(original)
                args = dict(file_metadata_source=source, file_metadata_titles=['File:Voice.ogg'])
                if change != 'omitted': args['snapshot_metadata_refresh'] = receipt
                if change not in ('allowed', 'nlink-during-validation'):
                    with self.assertRaises(ValueError): cache.prepare_wikibase_provider_update(root, dump, seal, **args)
                    self.assertEqual(seal, self.binding(root)); continue
                proof = cache.prepare_wikibase_provider_update(root, dump, seal, **args)
                hashes = self.stage_file(root, source)
                if change == 'nlink-during-validation':
                    real = cache.tool_identity
                    def link_after_worker(path):
                        value = real(path)
                        if Path(path) == root / 'dict-bundle-expander': cache.os.link(target, target.with_suffix('.linked'))
                        return value
                    with mock.patch.object(cache, 'tool_identity', side_effect=link_after_worker):
                        with self.assertRaises(ValueError): cache.finish_wikibase_provider_update(proof, hashes)
                    self.assertEqual(seal, self.binding(root)); continue
                current = cache.finish_wikibase_provider_update(proof, hashes)
                (root / '.incomplete').unlink(); after = cache.frozen_runtime_context(root, dump, current)
                for name in ('origin_graph', 'link'): self.assertEqual(record[name], after[name])
                for name in ('producer', 'source', 'verified_input', 'runtime_libraries', 'plans'): self.assertEqual(record['identity'][name], after['identity'][name])
                self.assertEqual(record['identity']['providers']['figure-page-observations.json'], after['identity']['providers']['figure-page-observations.json'])
                self.assertEqual(receipt['current_stamp'], after['runtime_stamps']['assets']['figure-page-observations.json'])
                self.assertEqual(record, proof['original_record'])

    def test_audio_append_preserves_original_native_source_and_publishes_explicit_data_origin(self):
        root, dump, snapshots, original = self.file_fixture()
        seal = self.binding(root); before = cache.read_marker(root / cache.COMPLETED_EXPANDER)
        raw = (root / cache.COMPLETED_EXPANDER).read_bytes()
        pins = {name: ((root / name).read_bytes(), cache._full_stamp((root / name).stat()))
                for name in ('dict-bundle-expander', 'lua-program.meta', 'modules/123.lua')}
        source = self.source(root); source_before = (cache._full_stamp(Path(source['path']).stat()), Path(source['path']).stat().st_nlink)
        old_before = (original.read_bytes(), cache._full_stamp(original.stat()), original.stat().st_nlink)
        # Current orchestration source is not substituted for an old native producer.
        (self.project / 'tools/extraction_cache.py').write_bytes(b'new live helper policy')
        proof = self.prepare_file(root, dump, source)
        current = cache.finish_wikibase_provider_update(proof, self.stage_file(root, source))
        self.assertIsNone(cache.frozen_runtime_context(root, dump, current))
        self.assertEqual('ordinary-file-metadata-provider-update', cache.frozen_runtime_context(root, dump, current, provider_update=True)['provenance'])
        (root / '.incomplete').unlink(); after = cache.frozen_runtime_context(root, dump, current)
        self.assertEqual(seal, after['provider_update']['original_seal_sha256'])
        self.assertEqual(before['identity']['providers']['file-metadata.tsv'], after['provider_update']['original_providers']['file-metadata.tsv'])
        self.assertEqual([source['bytes'], source['sha256']], after['identity']['providers']['file-metadata.tsv'])
        for field in ('origin_graph', 'link'): self.assertEqual(before[field], after[field])
        for field in ('producer', 'source', 'verified_input', 'runtime_libraries', 'plans'): self.assertEqual(before['identity'][field], after['identity'][field])
        for name in before['identity']['providers']:
            if name != 'file-metadata.tsv': self.assertEqual(before['identity']['providers'][name], after['identity']['providers'][name])
        for name, (body, stamp) in pins.items(): self.assertEqual((body, stamp), ((root / name).read_bytes(), cache._full_stamp((root / name).stat())))
        self.assertEqual(old_before, (original.read_bytes(), cache._full_stamp(original.stat()), original.stat().st_nlink))
        self.assertEqual(source_before, (cache._full_stamp(Path(source['path']).stat()), Path(source['path']).stat().st_nlink))
        self.assertEqual(source['path'], cache.os.readlink(root / 'file-metadata.tsv'))
        self.assertNotEqual(raw, (root / cache.COMPLETED_EXPANDER).read_bytes())

    def test_audio_append_refuses_changed_deleted_duplicate_schema_and_non_audio_rows(self):
        for change in ('changed', 'deleted', 'duplicate', 'header', 'bitmap', 'axes', 'exists', 'namespace', 'alias', 'extra', 'missing-newline', 'old-row-crlf', 'new-row-crlf'):
            with self.subTest(change=change):
                root, dump, snapshots, original = self.file_fixture(); before = (root / cache.COMPLETED_EXPANDER).read_bytes()
                raw = original.read_bytes(); addition = b'File:Voice.ogg\t1\t0\t0\tAUDIO\tFile:Actual.oga\n'
                if change == 'changed': raw = raw.replace(b'\t10\t20\t', b'\t11\t20\t')
                elif change == 'deleted': raw = raw.splitlines(keepends=True)[0]
                elif change == 'duplicate': addition += addition
                elif change == 'header': raw = raw.replace(b'-v2\n', b'-v1\n')
                elif change == 'bitmap': addition = addition.replace(b'AUDIO', b'BITMAP')
                elif change == 'axes': addition = addition.replace(b'\t0\t0\t', b'\t1\t0\t')
                elif change == 'exists': addition = addition.replace(b'\t1\t0\t0\t', b'\t0\t0\t0\t')
                elif change == 'namespace': addition = addition.replace(b'File:Voice', b'Other:Voice')
                elif change == 'alias': addition = addition.replace(b'File:Actual.oga', b'-')
                elif change == 'extra': addition += b'File:Zextra.ogg\t1\t0\t0\tAUDIO\tFile:Zextra.ogg\n'
                if change == 'old-row-crlf': raw = raw[:-1] + b'\r\n'
                elif change == 'new-row-crlf': addition = addition[:-1] + b'\r\n'
                if change == 'missing-newline': addition = addition.rstrip(b'\n')
                source = self.source(root, raw + addition)
                with self.assertRaises(ValueError): self.prepare_file(root, dump, source)
                self.assertEqual(before, (root / cache.COMPLETED_EXPANDER).read_bytes()); self.assertFalse((root / '.incomplete').exists())

    def test_audio_additions_before_between_and_after_original_rows(self):
        header = b'# wikidict-file-metadata-v2\n'
        def row(title):
            return f'File:{title}\t1\t0\t0\tAUDIO\tFile:{title}\n'.encode()
        original = header + row('B') + row('D')
        current = header + b''.join(map(row, 'ABCDE'))
        selected = ['File:E', 'File:A', 'File:C']
        self.assertEqual(sorted(selected), cache._file_metadata_audio_append(original, current, selected))
        for changed in (original[:-1], header + row('D') + row('B'), original + row('F')):
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                cache._file_metadata_audio_append(changed, current, selected)

    def test_audio_append_requires_exact_selected_hash_titles_and_external_source(self):
        for change in ('hash', 'bytes', 'titles', 'duplicate-titles', 'symlink', 'original'):
            with self.subTest(change=change):
                root, dump, snapshots, original = self.file_fixture(); source = self.source(root); titles = ['File:Voice.ogg']
                if change == 'hash': source['sha256'] = '0' * 64
                elif change == 'bytes': source['bytes'] += 1
                elif change == 'titles': titles = ['File:Other.ogg']
                elif change == 'duplicate-titles': titles *= 2
                elif change == 'symlink':
                    link = self.base / (str(self.sequence) + '-alias'); link.symlink_to(source['path']); source['path'] = str(link)
                elif change == 'original': source = dict(path=str(original), bytes=original.stat().st_size, sha256=cache.sha256(original))
                with self.assertRaises(ValueError): self.prepare_file(root, dump, source, titles)
                self.assertFalse((root / '.incomplete').exists())

    def test_audio_append_refuses_native_plan_source_other_provider_and_tool_drift(self):
        for change in ('worker', 'module', 'plan', 'dump', 'other-provider', 'other-provider-same-bytes', 'graph-runtime', 'graph-runtime-same-bytes', 'library'):
            with self.subTest(change=change):
                root, dump, snapshots, original = self.file_fixture(); source = self.source(root); proof = self.prepare_file(root, dump, source); old = self.binding(root)
                hashes = self.stage_file(root, source)
                if change == 'worker': (root / 'dict-bundle-expander').write_bytes(b'changed worker')
                elif change == 'module': (root / 'modules/123.lua').write_bytes(b'return 2')
                elif change == 'plan': (root.parent / 'module-compile-plan.tsv').write_bytes(b'changed plan')
                elif change == 'dump': dump.write_bytes(b'changed dump')
                elif change.startswith('other-provider'):
                    target = Path(snapshots['interface-messages.tsv']); raw = target.read_bytes()
                    if change.endswith('same-bytes'):
                        new = target.with_suffix('.new'); new.write_bytes(raw); new.replace(target)
                    else: target.write_bytes(b'other provider changed')
                elif change.startswith('graph-runtime'):
                    target = Path(self.graph['runtime'])
                    if change.endswith('same-bytes'):
                        new = target.with_suffix('.new'); new.write_bytes(target.read_bytes()); new.replace(target)
                    else: target.write_bytes(b'new runtime')
                else: self.library.write_bytes(b'new library')
                with self.assertRaises(ValueError): cache.finish_wikibase_provider_update(proof, hashes)
                self.assertEqual(old, self.binding(root)); self.assertEqual(cache.FILE_METADATA_UPDATE_MARKER, (root / '.incomplete').read_bytes())

    def test_audio_append_refuses_source_ctime_alias_and_selected_authority_drift(self):
        for change in ('original', 'selected', 'retarget', 'expected-hash', 'marker', 'original-during-validation', 'graph-during-validation'):
            with self.subTest(change=change):
                root, dump, snapshots, original = self.file_fixture(); source = self.source(root); proof = self.prepare_file(root, dump, source); old = self.binding(root)
                hashes = self.stage_file(root, source)
                if change.endswith('during-validation'):
                    observed = cache.tool_identity
                    def mutate_after_worker(path):
                        value = observed(path)
                        if Path(path) == root / 'dict-bundle-expander':
                            target = original if change.startswith('original') else Path(self.graph['runtime'])
                            info = target.stat(); target.write_bytes(target.read_bytes()); cache.os.utime(target, ns=(info.st_atime_ns, info.st_mtime_ns))
                        return value
                    with mock.patch.object(cache, 'tool_identity', side_effect=mutate_after_worker):
                        with self.assertRaises(ValueError): cache.finish_wikibase_provider_update(proof, hashes)
                    self.assertEqual(old, self.binding(root)); continue
                if change in ('original', 'selected'):
                    path = original if change == 'original' else Path(source['path']); info = path.stat(); raw = path.read_bytes(); path.write_bytes(raw); cache.os.utime(path, ns=(info.st_atime_ns, info.st_mtime_ns))
                elif change == 'retarget':
                    (root / 'file-metadata.tsv').unlink(); (root / 'file-metadata.tsv').symlink_to(original)
                elif change == 'expected-hash': hashes['file-metadata.tsv'] = '0' * 64
                else: (root / '.incomplete').write_bytes(cache.PROVIDER_UPDATE_MARKER)
                with self.assertRaises(ValueError): cache.finish_wikibase_provider_update(proof, hashes)
                self.assertEqual(old, self.binding(root))

    def test_audio_append_publication_failure_preserves_old_seal_and_unready_marker(self):
        for change in ('write-failure', 'original-after-publication', 'graph-after-publication'):
            with self.subTest(change=change):
                root, dump, snapshots, original = self.file_fixture(); source = self.source(root); proof = self.prepare_file(root, dump, source); old = (root / cache.COMPLETED_EXPANDER).read_bytes(); hashes = self.stage_file(root, source)
                write = cache.write_private_marker
                def publication(path, value):
                    if change == 'write-failure': raise OSError('injected publication failure')
                    write(path, value)
                    target = original if change.startswith('original') else Path(self.graph['runtime'])
                    info = target.stat(); target.write_bytes(target.read_bytes()); cache.os.utime(target, ns=(info.st_atime_ns, info.st_mtime_ns))
                with mock.patch.object(cache, 'write_private_marker', side_effect=publication):
                    with self.assertRaises(OSError if change == 'write-failure' else ValueError): cache.finish_wikibase_provider_update(proof, hashes)
                if change == 'write-failure': self.assertEqual(old, (root / cache.COMPLETED_EXPANDER).read_bytes())
                self.assertEqual(cache.FILE_METADATA_UPDATE_MARKER, (root / '.incomplete').read_bytes())
                self.assertIsNone(cache.frozen_runtime_context(root, dump, cache.sha256(root / cache.COMPLETED_EXPANDER)))

    def test_audio_append_repeated_updates_keep_first_origin_and_reject_mixed_families(self):
        root, dump, snapshots, original = self.file_fixture(); first = self.binding(root); previous = first
        for index, title in enumerate(('File:Voice.ogg', 'File:Voice2.ogg')):
            raw = (root / 'file-metadata.tsv').read_bytes() + (title + '\t1\t0\t0\tAUDIO\tFile:Actual.oga\n').encode()
            source = self.source(root, raw, suffix='repeat-' + str(index)); proof = self.prepare_file(root, dump, source, [title]); current = cache.finish_wikibase_provider_update(proof, self.stage_file(root, source)); (root / '.incomplete').unlink()
            after = cache.frozen_runtime_context(root, dump, current)
            self.assertEqual(first, after['provider_update']['original_seal_sha256']); self.assertEqual(previous, after['provider_update']['previous_seal_sha256']); previous = current
        with self.assertRaises(ValueError): cache.prepare_wikibase_provider_update(root, dump, previous)




class SnapshotMetadataRefreshListTests(MetadataCustodyRefreshTests):
    def refresh_fixture(self):
        root,dump,snapshots=self.fixture(ready=False)
        extra=self.base/('refresh-figure-site-'+str(self.sequence));extra.write_bytes(b'original figure site')
        snapshots['figure-siteinfo.raw.json']=str(extra);(root/'figure-siteinfo.raw.json').symlink_to(extra)
        self.call('seal-expander',root,dump,snapshots);cache.shutil.rmtree(root/'llvm')
        (root/'.incomplete').unlink();(root.parent/'.incomplete').write_bytes(b'expander ready')
        seal=self.binding(root);record=cache.read_marker(root/cache.COMPLETED_EXPANDER);members=[]
        for name in ('figure-siteinfo.raw.json','namespace-registry.tsv'):
            source=Path(snapshots[name]);cache.os.link(source,self.base/('refresh-link-'+str(self.sequence)+'-'+name))
            members.append(dict(name=name,source=str(source),original_seal_sha256=seal,
                old_stamp=record['runtime_stamps']['assets'][name],current_stamp=list(cache._full_stamp(source.stat())),
                current_nlink=source.stat().st_nlink,ctime_cause='unknown',alias_stamp=list(cache._full_stamp((root/name).lstat()))))
        return root,dump,snapshots,seal,record,dict(original_seal_sha256=seal,snapshots=members)

    def test_snapshot_refresh_list_preserves_bytes_original_record_and_owned_stamp_lists(self):
        root,dump,snapshots,seal,record,receipt=self.refresh_fixture();raw=(root/cache.COMPLETED_EXPANDER).read_bytes();original=json.loads(json.dumps(record))
        with self.assertRaises(ValueError):cache.frozen_runtime_context(root,dump,seal)
        refreshed=cache.frozen_runtime_context(root,dump,seal,snapshot_metadata_refresh=receipt)
        self.assertEqual(record,original);self.assertEqual(raw,(root/cache.COMPLETED_EXPANDER).read_bytes())
        for name in ('identity','origin_graph','link'):self.assertEqual(refreshed[name],record[name])
        direct=cache._snapshot_metadata_refresh(root,record,seal,receipt)
        self.assertIs(direct['identity'],record['identity']);self.assertIsNot(direct['runtime_stamps']['assets'],record['runtime_stamps']['assets'])
        selected=receipt['snapshots'][0];saved=list(direct['runtime_stamps']['assets'][selected['name']]);selected['current_stamp'][5]+=1
        self.assertEqual(saved,direct['runtime_stamps']['assets'][selected['name']]);self.assertEqual(record,original)

    def test_snapshot_refresh_list_refuses_nonmetadata_alias_and_concurrent_changes(self):
        import stat
        for change in ('omitted','unsorted','duplicate','unlisted','content','inode','mode','mtime','alias','same-alias','nlink','late-alias','native'):
            with self.subTest(change=change):
                root,dump,snapshots,seal,record,receipt=self.refresh_fixture();row=receipt['snapshots'][0];source=Path(row['source']);before=source.stat();alias=root/row['name']
                if change=='unsorted':receipt['snapshots'].reverse()
                elif change=='duplicate':receipt['snapshots'].append(dict(row))
                elif change=='unlisted':row['name']='not-a-snapshot'
                elif change=='content':
                    source.write_bytes(b'x'*before.st_size);cache.os.utime(source,ns=(before.st_atime_ns,before.st_mtime_ns));row['current_stamp']=list(cache._full_stamp(source.stat()))
                elif change=='inode':
                    raw=source.read_bytes();source.unlink();source.write_bytes(raw);cache.os.utime(source,ns=(before.st_atime_ns,before.st_mtime_ns));row['current_stamp']=list(cache._full_stamp(source.stat()))
                elif change=='mode':source.chmod(stat.S_IMODE(before.st_mode)^0o100);row['current_stamp']=list(cache._full_stamp(source.stat()))
                elif change=='mtime':cache.os.utime(source,ns=(before.st_atime_ns,before.st_mtime_ns+1));row['current_stamp']=list(cache._full_stamp(source.stat()))
                elif change in ('alias','same-alias'):
                    alias.unlink();alias.symlink_to(source if change=='same-alias'else Path(snapshots['namespace-registry.tsv']))
                elif change=='nlink':cache.os.link(source,self.base/('unrecorded-link-'+str(self.sequence)))
                elif change=='native':(root/'dict-bundle-expander').write_bytes(b'changed native worker')
                kwargs={}if change=='omitted'else dict(snapshot_metadata_refresh=receipt)
                if change=='late-alias':
                    real=cache.stable_file_digest;last=Path(receipt['snapshots'][-1]['source'])
                    def replace_after_last(path,**options):
                        value=real(path,**options)
                        if Path(path)==last:alias.unlink();alias.symlink_to(source)
                        return value
                    with mock.patch.object(cache,'stable_file_digest',side_effect=replace_after_last),self.assertRaises(ValueError):cache.frozen_runtime_context(root,dump,seal,**kwargs)
                else:
                    with self.assertRaises(ValueError):cache.frozen_runtime_context(root,dump,seal,**kwargs)

class SitelinksProviderUpdateTests(unittest.TestCase):
    setUp = CompletedExpanderTests.setUp
    fixture = CompletedExpanderTests.fixture
    call = CompletedExpanderTests.call
    binding = CompletedExpanderTests.binding

    def test_first_sitelink_requires_exactly_one_observed_positive_pair(self):
        positive = ['Q1860', 'zhwiki', 'English']
        payload = b'# source\nQ1860\tzhwiki\tEnglish\n'
        self.assertEqual(cache._sitelinks_append(None, payload, [positive]), [positive])
        for row in (['Q1860', 'zhwiki', ''], ['Q1860', '*', '']):
            with self.subTest(row=row), self.assertRaises(ValueError):
                cache._sitelinks_append(None, ('\t'.join(row) + '\n').encode(), [row])
        with self.assertRaises(ValueError):
            cache._sitelinks_append(None, payload + b'Q2\tzhwiki\tEarth\n', [positive, ['Q2', 'zhwiki', 'Earth']])

    def sitelinks_fixture(self):
        self.zig_tool['tool_sha256'] = cache.sha256(Path(self.graph['zig']))
        self.tool['tool'] = cache.tool_identity(Path(self.graph['clang']))
        root, dump, snapshots = self.fixture(ready=False)
        original = self.base / ('sitelinks-origin-' + str(self.sequence))
        original.write_bytes(b'# entity_id\tglobal_site_id\tpage_title\nQ7850\tviwiki\tOld title\n')
        snapshots['wikibase-sitelinks.tsv'] = str(original)
        (root / 'wikibase-sitelinks.tsv').symlink_to(original)
        self.call('seal-expander', root, dump, snapshots)
        cache.shutil.rmtree(root / 'llvm')
        (root / '.incomplete').unlink(); (root.parent / '.incomplete').write_bytes(b'expander ready')
        source = self.base / ('sitelinks-selected-' + str(self.sequence))
        source.write_bytes(original.read_bytes() + b'Q1860\tviwiki\tEnglish\nQ33090\tviwiki\t\n')
        descriptor = dict(path=str(source), bytes=source.stat().st_size, sha256=cache.sha256(source))
        rows = [['Q1860', 'viwiki', 'English'], ['Q33090', 'viwiki', '']]
        return root, dump, original, descriptor, rows

    def test_sitelinks_singleton_preserves_native_origin_and_explicit_absence(self):
        root, dump, original, source, rows = self.sitelinks_fixture()
        old = cache.read_marker(root / cache.COMPLETED_EXPANDER)
        old_raw = original.read_bytes(); seal = self.binding(root)
        proof = cache.prepare_wikibase_provider_update(root, dump, seal, sitelinks_source=source, sitelinks_rows=rows)
        (root / '.incomplete').write_bytes(cache.SITELINKS_UPDATE_MARKER)
        alias = root / '.sitelinks-update.part'; alias.symlink_to(source['path']); alias.replace(root / 'wikibase-sitelinks.tsv')
        current = cache.finish_wikibase_provider_update(proof, {'wikibase-sitelinks.tsv': source['sha256']})
        self.assertIsNotNone(cache.frozen_runtime_context(root, dump, current, provider_update=True))
        (root / '.incomplete').unlink()
        after = cache.frozen_runtime_context(root, dump, current)
        self.assertEqual(after['provenance'], 'ordinary-sitelinks-provider-update')
        self.assertEqual(after['provider_update']['original_seal_sha256'], seal)
        self.assertEqual(original.read_bytes(), old_raw)
        for key in ('producer', 'source', 'runtime_libraries', 'plans', 'verified_input'):
            self.assertEqual(after['identity'][key], old['identity'][key])
        for key in ('origin_graph', 'link'):
            self.assertEqual(after[key], old[key])
        self.assertEqual(after['identity']['providers']['wikibase-sitelinks.tsv'], [source['bytes'], source['sha256']])
        self.assertEqual(cache._sitelinks_append(old_raw, Path(source['path']).read_bytes(), rows), rows)

    def test_sitelinks_delta_refuses_changed_old_fact_duplicate_and_unselected_absence(self):
        before = b'# source\nQ7850\tviwiki\tOld title\n'
        good = before + b'Q33090\tviwiki\t\n'
        for raw, rows in ((good, []), (good, [['Q33090', 'viwiki', 'invented']]),
                (good.replace(b'\n', b'\r\n'), [['Q33090', 'viwiki', '']]),
                (good.replace(b'Old title', b'other'), [['Q33090', 'viwiki', '']]),
                (good + b'Q33090\tviwiki\t\n', [['Q33090', 'viwiki', '']]),
                (good.replace(b'# source', b'# other'), [['Q33090', 'viwiki', '']]),
                (good, [['Q7850', 'viwiki', 'Old title'], ['Q33090', 'viwiki', '']])):
            with self.subTest(raw=raw, rows=rows), self.assertRaises(ValueError):
                cache._sitelinks_append(before, raw, rows)

    def test_sitelinks_transaction_refuses_source_native_other_provider_and_marker_drift(self):
        for change in ('source', 'worker', 'other-provider', 'marker', 'mixed'):
            with self.subTest(change=change):
                root, dump, original, source, rows = self.sitelinks_fixture()
                proof = cache.prepare_wikibase_provider_update(root, dump, self.binding(root), sitelinks_source=source, sitelinks_rows=rows)
                old_seal = (root / cache.COMPLETED_EXPANDER).read_bytes()
                (root / '.incomplete').write_bytes(cache.SITELINKS_UPDATE_MARKER)
                alias = root / '.sitelinks-update.part'; alias.symlink_to(source['path']); alias.replace(root / 'wikibase-sitelinks.tsv')
                if change == 'source': Path(source['path']).write_bytes(b'changed source')
                elif change == 'worker': (root / 'dict-bundle-expander').write_bytes(b'changed native worker')
                elif change == 'other-provider':
                    target = self.base / ('foreign-provider-' + str(self.sequence)); target.write_bytes(b'foreign')
                    (root / 'file-metadata.tsv').symlink_to(target)
                elif change == 'marker': (root / '.incomplete').write_bytes(cache.FILE_METADATA_UPDATE_MARKER)
                else: proof['file_metadata_update'] = proof['sitelinks_update']
                with self.assertRaises((ValueError, OSError)):
                    cache.finish_wikibase_provider_update(proof, {'wikibase-sitelinks.tsv': source['sha256']})
                self.assertEqual((root / cache.COMPLETED_EXPANDER).read_bytes(), old_seal)




class KnownMaterializationCustodyTests(unittest.TestCase):
    setUp = CompletedExpanderTests.setUp
    fixture = CompletedExpanderTests.fixture
    call = CompletedExpanderTests.call
    binding = CompletedExpanderTests.binding
    payload_names = ('file-metadata.tsv', 'figure-file-inventory.json', 'figure-sizing.json', 'figure-sizing.raw.json')

    def known_fixture(self, *, failed=False, links=4, cleanup=0, prior=False, legacy=False):
        from types import SimpleNamespace
        root, dump, snapshots = self.fixture(ready=False)
        source = self.base / ('known-source-' + str(self.sequence)); source.mkdir()
        native_names = (*self.payload_names, 'figure-siteinfo.raw.json', 'figure-sizing.site.json')
        for name in native_names:
            path = source / name; path.write_bytes(('original ' + name).encode())
            if name in cache.EXPANDER_SNAPSHOTS:
                snapshots[name] = str(path); (root / name).symlink_to(path)
        self.call('seal-expander', root, dump, snapshots); cache.shutil.rmtree(root / 'llvm')
        (root / '.incomplete').unlink(); (root.parent / '.incomplete').write_bytes(b'expander ready')
        seal = self.binding(root); original = cache.read_marker(root / cache.COMPLETED_EXPANDER)
        def ref(path): return dict(path=str(path), bytes=path.stat().st_size, sha256=cache.sha256(path))
        def write(path, value): path.write_text(json.dumps(value)); return ref(path)
        def info(path): return {key:getattr(path.stat(),key) for key in ('st_dev','st_ino','st_mode','st_uid','st_gid','st_size','st_mtime_ns','st_ctime_ns','st_nlink')}
        if prior:
            cache.os.link(source / self.payload_names[0], self.base / ('prior-known-' + str(self.sequence)))
        old_refresh = None
        if legacy:
            name = 'namespace-registry.tsv'; path = Path(snapshots[name])
            cache.os.link(path, self.base / ('historical-namespace-' + str(self.sequence)))
            old_refresh = dict(original_seal_sha256=seal, snapshots=[dict(name=name, source=str(path),
                original_seal_sha256=seal, old_stamp=original['runtime_stamps']['assets'][name],
                current_stamp=list(cache._full_stamp(path.stat())), current_nlink=path.stat().st_nlink,
                ctime_cause='unknown', alias_stamp=list(cache._full_stamp((root/name).lstat())))])
        artifacts = {name:dict(bytes=(source/name).stat().st_size, sha256=cache.sha256(source/name)) for name in native_names}
        manifest = write(source / 'figure-inputs.manifest.json', dict(artifacts=artifacts))
        before = {name:info(source/name) for name in self.payload_names}
        output = self.base / ('known-output-' + str(self.sequence)); output.mkdir()
        removed = []; events = []
        for name in self.payload_names[:links]:
            cache.os.link(source/name, output/name)
            events.append(dict(path=name,before=before[name],after=info(source/name),
                sha256_before=artifacts[name]['sha256'],sha256_after=cache.sha256(source/name)))
        for name in self.payload_names[:cleanup]:
            held = info(output/name); (output/name).unlink()
            removed.append(dict(path=name,target=str(output/name),before=held,after=info(source/name)))
        members = [dict(path=name,before=before[name],after=info(source/name),
            sha256_before=artifacts[name]['sha256'],sha256_after=cache.sha256(source/name)) for name in self.payload_names]
        touched = events
        remaining = [dict(path=name,target=str(output/name),stamp=info(output/name)) for name in self.payload_names if (output/name).exists()]
        state = output.stat(); directory = dict(path=str(output),device=state.st_dev,inode=state.st_ino,mode=state.st_mode,uid=state.st_uid)
        observations = dict(operation='materialize-complete',complete=not failed,source_complete_verified=True,
            source_content_mode_inode_preserved=True,source_manifest_sha256=manifest['sha256'],
            original_members=members,linked_members=touched,remaining_owned_links=remaining,
            removed_owned_links=removed,output_root=directory)
        if failed: observations.update(new_output_adoption_allowed=False,failed_link_recovery_verified=True)
        output_manifest = None if failed else write(output/'figure-inputs.manifest.json',dict(artifacts=artifacts))
        common = dict(source_after=True,source_lease_released=True,allocation_released=True)
        operation = dict(common,outcome=('FAILED' if failed else 'PASSED')+'-PHYSICALLY-SOURCE-CLOSED',
            observations=None,linked_members=touched,source_manifest=manifest,output_manifest=output_manifest)
        selected = manifest if failed else output_manifest
        selected_root = Path(selected['path']).parent
        if not failed:
            for name in ('figure-siteinfo.raw.json','figure-sizing.site.json'):
                (output/name).write_bytes((source/name).read_bytes())
        native_argv = ['qualified-fixture-driver','--check-figure-compatibility','--full',
            str(Path(snapshots['namespace-registry.tsv']).resolve()),
            *(str(selected_root/name) for name in ('figure-siteinfo.raw.json','figure-sizing.json',
                'figure-sizing.raw.json','figure-sizing.site.json'))]
        compatibility = write(self.base/('known-native-result-'+str(self.sequence)+'.json'),dict(returncode=0,
            ordinary_full_stream_validation=True,input_after=True,pages_executed=0,compiler_executed=False,
            argv=native_argv))
        native = dict(common,outcome='PASSED-PHYSICALLY-SOURCE-CLOSED',native_returncode=0,
            ordinary_full_stream_validation=True,pages_executed=0,compiler_executed=False,
            validated_manifest=selected,compatibility=compatibility)
        receipt = dict(original_seal_sha256=seal,operation=None,native_validation=None,
            names=sorted(name for name in self.payload_names if name in cache.EXPANDER_SNAPSHOTS))
        f = SimpleNamespace(**locals())
        self.publish_known(f)
        return f

    def publish_known(self, f):
        prefix = self.base / ('known-proof-' + str(self.sequence))
        f.operation['observations'] = f.write(prefix.with_suffix('.observations.json'), f.observations)
        f.receipt['operation'] = f.write(prefix.with_suffix('.operation.json'), f.operation)
        f.receipt['native_validation'] = f.write(prefix.with_suffix('.native.json'), f.native)

    def known_context(self, f):
        options = dict(metadata_custody_refresh=f.receipt)
        if f.old_refresh is not None: options['snapshot_metadata_refresh'] = f.old_refresh
        return cache.frozen_runtime_context(f.root,f.dump,f.seal,**options)

    def test_complete_known_links_keep_original_native_identity_and_exact_owned_targets(self):
        import stat
        f = self.known_fixture(); raw = (f.root/cache.COMPLETED_EXPANDER).read_bytes()
        with self.assertRaises(ValueError): cache.frozen_runtime_context(f.root,f.dump,f.seal)
        current = self.known_context(f)
        for key in ('identity','origin_graph','link','provenance'): self.assertEqual(current[key],f.original[key])
        for name in f.receipt['names']:
            self.assertEqual(current['runtime_stamps']['assets'][name],list(cache._full_stamp((f.root/name).stat())))
        self.assertEqual((f.root/cache.COMPLETED_EXPANDER).read_bytes(),raw)
        self.assertEqual(len(f.observations['remaining_owned_links']),4)
        other = self.base / ('other-output-' + str(self.sequence)); other.mkdir()
        value = other.stat()
        f.observations['output_root'] = dict(path=str(other),device=value.st_dev,
            inode=value.st_ino,mode=value.st_mode,uid=value.st_uid)
        self.publish_known(f)
        with self.assertRaisesRegex(ValueError,'another operation root'): self.known_context(f)

    def test_failed_links_and_explicit_partial_cleanup_restore_only_original_context(self):
        for links,cleanup in ((1,0),(2,1),(4,4),(0,0)):
            with self.subTest(links=links,cleanup=cleanup):
                f = self.known_fixture(failed=True,links=links,cleanup=cleanup)
                raw = (f.root/cache.COMPLETED_EXPANDER).read_bytes(); current = self.known_context(f)
                self.assertEqual(current['identity'],f.original['identity']); self.assertIsNone(f.operation['output_manifest'])
                self.assertFalse(f.observations['new_output_adoption_allowed'])
                self.assertEqual(len(f.observations['remaining_owned_links']),links-cleanup)
                self.assertEqual(len(f.observations['removed_owned_links']),cleanup)
                self.assertEqual((f.root/cache.COMPLETED_EXPANDER).read_bytes(),raw)

    def test_known_full_revalidation_and_disjoint_historical_refresh_do_not_relabel_events(self):
        f = self.known_fixture(failed=True,links=2,cleanup=1,prior=True,legacy=True)
        current = self.known_context(f)
        self.assertEqual(current['identity'],f.original['identity'])
        self.assertNotIn('ctime_cause',f.observations)
        self.assertEqual(current['runtime_stamps']['assets']['namespace-registry.tsv'],f.old_refresh['snapshots'][0]['current_stamp'])
        f.old_refresh['snapshots'][0]['name'] = f.receipt['names'][0]
        with self.assertRaises(ValueError): self.known_context(f)
        with self.assertRaises(ValueError): cache.frozen_runtime_context(f.root,f.dump,f.seal,metadata_custody_refresh=f.receipt,provider_update=True)

    def test_failed_recovery_refuses_unproved_cleanup_output_adoption_and_wrong_native_tuple(self):
        for change in ('unverified','missing-original','missing-removal','foreign-removal','wrong-target',
                       'new-output','wrong-native-root','repaired-label','unknown-mode','remaining-stamp','late-complete',
                       'fictitious-root-flag','wrong-namespace','mixed-native-path','output-permission-mode'):
            with self.subTest(change=change):
                f = self.known_fixture(failed=True,links=2,cleanup=1)
                if change=='unverified': f.observations['failed_link_recovery_verified']=False
                elif change=='missing-original': f.observations['original_members'].pop()
                elif change=='missing-removal': f.observations['removed_owned_links']=[]
                elif change=='foreign-removal': f.observations['removed_owned_links'][0]['before']['st_ino']+=1
                elif change=='wrong-target': f.observations['remaining_owned_links'][0]['target']=str(self.base/'foreign')
                elif change=='new-output': f.observations['new_output_adoption_allowed']=True
                elif change=='wrong-native-root': f.native['validated_manifest']=dict(f.operation['source_manifest'],path=str(f.output/'figure-inputs.manifest.json'))
                elif change=='repaired-label': f.native['repaired_manifest']=f.operation['source_manifest']
                elif change=='unknown-mode': f.observations['operation']='unknown'
                elif change=='output-permission-mode': f.observations['output_root']['mode'] &= 0o777
                elif change=='late-complete': (f.output/'figure-inputs.complete.json').write_text('{}')
                elif change in ('fictitious-root-flag','wrong-namespace','mixed-native-path','output-permission-mode'):
                    value=json.loads(Path(f.compatibility['path']).read_text())
                    if change=='fictitious-root-flag': value['argv']=['qualified-fixture-driver','--check-figure-compatibility','--full','--figure-input-root',str(f.source)]
                    elif change=='wrong-namespace': value['argv'][3]=str(self.base/'foreign-namespace')
                    else: value['argv'][5]=str(f.output/'figure-sizing.json')
                    f.native['compatibility']=f.write(Path(f.compatibility['path']),value)
                else: f.observations['remaining_owned_links'][0]['stamp']['st_nlink']+=1
                self.publish_known(f)
                with self.assertRaises((ValueError,OSError)): self.known_context(f)

    def test_known_custody_refuses_changed_bytes_inode_mode_mtime_and_unrecorded_links(self):
        for change in ('bytes','inode','mode','mtime','extra-link','retarget','removed-reappeared'):
            with self.subTest(change=change):
                f = self.known_fixture(failed=True,links=2,cleanup=1); path=f.source/'figure-sizing.raw.json';old=path.stat()
                if change=='bytes': path.write_bytes(b'x'*old.st_size);cache.os.utime(path,ns=(old.st_atime_ns,old.st_mtime_ns))
                elif change=='inode': replacement=f.source/'replacement';replacement.write_bytes(path.read_bytes());replacement.replace(path)
                elif change=='mode': path.chmod((old.st_mode&0o777)^0o100)
                elif change=='mtime': cache.os.utime(path,ns=(old.st_atime_ns,old.st_mtime_ns+1))
                elif change=='extra-link': cache.os.link(path,self.base/('unrecorded-'+str(self.sequence)))
                elif change=='removed-reappeared': cache.os.link(f.source/self.payload_names[0],f.output/self.payload_names[0])
                else:
                    alias=f.root/'figure-sizing.json';alias.unlink();alias.symlink_to(f.source/'figure-sizing.raw.json')
                with self.assertRaises(ValueError): self.known_context(f)

    def test_known_custody_rechecks_authorities_and_source_after_native_source_binding(self):
        f = self.known_fixture(failed=True,links=1)
        old = cache.completed_source_binding
        def mutate_after_source(root,dump):
            value=old(root,dump)
            path=Path(f.operation['observations']['path']);path.write_bytes(path.read_bytes()+b' ')
            return value
        with mock.patch.object(cache,'completed_source_binding',side_effect=mutate_after_source),self.assertRaises(ValueError):
            self.known_context(f)

    def test_actual_materializer_observations_keep_original_context_and_refuse_permission_only_mode(self):
        import errno
        import prepare_figure_metadata as figure
        import test_prepare_figure_files as figure_tests
        from types import SimpleNamespace
        for failed in (False, True):
            with self.subTest(failed=failed):
                producer = figure_tests.OfflineFigureMaterializationTests()
                producer.setUp(); self.addCleanup(producer.doCleanups)
                args = producer.complete(); source = args.output
                root, dump, snapshots = self.fixture(ready=False)
                namespace = Path(snapshots['namespace-registry.tsv'])
                namespace.write_bytes((source/'site-info.namespace-registry.tsv').read_bytes())
                source_receipt = root/'extraction-source.json'
                value = json.loads(source_receipt.read_text())
                value['namespace_sha256'] = list(bytes.fromhex(cache.sha256(namespace)))
                source_receipt.write_text(json.dumps(value))
                for name in (*self.payload_names, 'figure-siteinfo.raw.json', 'figure-sizing.site.json'):
                    if name in cache.EXPANDER_SNAPSHOTS:
                        snapshots[name] = str(source/name); (root/name).symlink_to(source/name)
                self.call('seal-expander', root, dump, snapshots)
                cache.shutil.rmtree(root/'llvm'); (root/'.incomplete').unlink()
                (root.parent/'.incomplete').write_bytes(b'expander ready')
                seal = self.binding(root); original = cache.read_marker(root/cache.COMPLETED_EXPANDER)
                marker_before = (root/cache.COMPLETED_EXPANDER).read_bytes()
                observations = {}; output = producer.root/'custody-produced'
                if failed:
                    link = figure.os.link; calls = []
                    def fail_third(*args, **kwargs):
                        calls.append(args)
                        if len(calls) == 3: raise OSError(errno.ENOSPC, 'owned fixture failure')
                        return link(*args, **kwargs)
                    with mock.patch.object(figure.os, 'link', side_effect=fail_third), self.assertRaises(OSError):
                        figure.materialize_complete_capture(source/figure.MANIFEST, output,
                            link_current_payloads=True, observations=observations)
                    self.assertTrue(observations['failed_link_recovery_verified'])
                    self.assertFalse(observations['complete'])
                    self.assertEqual(len(observations['remaining_owned_links']), 2)
                else:
                    figure.materialize_complete_capture(source/figure.MANIFEST, output,
                        link_current_payloads=True, observations=observations)
                    self.assertTrue(observations['complete'])
                self.assertEqual(observations['output_root']['mode'], output.stat().st_mode)
                self.assertNotEqual(observations['output_root']['mode'], output.stat().st_mode & 0o777)
                def ref(path): return dict(path=str(path),bytes=path.stat().st_size,sha256=cache.sha256(path))
                def write(path, value): path.write_text(json.dumps(value)); return ref(path)
                manifest = ref(source/figure.MANIFEST)
                selected = manifest if failed else ref(output/figure.MANIFEST)
                common = dict(source_after=True, source_lease_released=True, allocation_released=True)
                operation = dict(common,outcome=('FAILED' if failed else 'PASSED')+'-PHYSICALLY-SOURCE-CLOSED',
                    observations=None,linked_members=observations['linked_members'],source_manifest=manifest,
                    output_manifest=None if failed else selected)
                selected_root = Path(selected['path']).parent
                compatibility = write(self.base/('produced-native-'+str(self.sequence)+'.json'),
                    dict(returncode=0,ordinary_full_stream_validation=True,input_after=True,
                        pages_executed=0,compiler_executed=False,
                        argv=['qualified-fixture-driver','--check-figure-compatibility','--full',str(namespace),
                            *(str(selected_root/name) for name in ('figure-siteinfo.raw.json','figure-sizing.json',
                                'figure-sizing.raw.json','figure-sizing.site.json'))]))
                native = dict(common,outcome='PASSED-PHYSICALLY-SOURCE-CLOSED',native_returncode=0,
                    ordinary_full_stream_validation=True,pages_executed=0,compiler_executed=False,
                    validated_manifest=selected,compatibility=compatibility)
                receipt = dict(original_seal_sha256=seal,operation=None,native_validation=None,
                    names=sorted(name for name in self.payload_names if name in cache.EXPANDER_SNAPSHOTS))
                f = SimpleNamespace(**locals(),old_refresh=None)
                self.publish_known(f)
                current = self.known_context(f)
                self.assertEqual(current['identity'], original['identity'])
                self.assertEqual((root/cache.COMPLETED_EXPANDER).read_bytes(), marker_before)
                observations['output_root']['mode'] &= 0o777
                self.publish_known(f)
                with self.assertRaisesRegex(ValueError, 'output identity changed'): self.known_context(f)



class RestoredDumpCustodyTests(unittest.TestCase):
    setUp = CompletedExpanderTests.setUp
    fixture = CompletedExpanderTests.fixture
    call = CompletedExpanderTests.call
    _trace_seal_digest_reads = CompletedExpanderTests._trace_seal_digest_reads

    def restored_fixture(self):
        root, dump, snapshots = self.fixture(ready=False)
        self.assertEqual(0, self.call('seal-expander', root, dump, snapshots, dump_sha=cache.sha256(dump)))
        cache.shutil.rmtree(root / 'llvm')
        (root / '.incomplete').unlink()
        (root.parent / '.incomplete').write_bytes(b'expander ready')
        marker = root / cache.COMPLETED_EXPANDER
        seal_sha = cache.sha256(marker)
        original = cache.frozen_runtime_context(root, dump, seal_sha)
        self.assertIsNotNone(original)
        held = {name: (root / name).read_bytes() for name in
                (cache.COMPLETED_EXPANDER, 'extraction-source.json', 'page-index.tsv',
                 'page-title-index.bin', 'dump-streams.tsv', 'dict-bundle-expander')}
        restored = self.base / ('restored-' + dump.name)
        restored.write_bytes(dump.read_bytes()); restored.chmod(0o644)
        descriptor = dict(path=str(restored), bytes=restored.stat().st_size,
                          sha256=cache.sha256(restored), mode=0o644)
        dump.unlink()
        return root, dump, restored, descriptor, seal_sha, original, held

    def test_exact_restored_compressed_bytes_keep_historical_origin_and_hash_once(self):
        root, old, restored, descriptor, seal_sha, original, held = self.restored_fixture()
        with self.assertRaises((ValueError, OSError)): cache.frozen_runtime_context(root, old, seal_sha)
        with self.assertRaises(ValueError): cache.completed_source_binding(root, restored)
        with self._trace_seal_digest_reads((restored,)) as reads:
            binding = cache.restored_dump_binding(root, descriptor, seal_sha)
            for _ in range(3):
                self.assertIs(cache.restored_dump_binding(root, descriptor, seal_sha, previous=binding), binding)
                self.assertEqual(cache.frozen_runtime_context(root, restored, seal_sha, restored_dump=binding), original)
        self.assertEqual(reads['bytes'], descriptor['bytes'])
        self.assertEqual(reads['opens'], 1)
        self.assertEqual(original['identity']['source']['path'], str(old))
        self.assertNotEqual(original['identity']['source']['receipt']['source']['inode'], restored.stat().st_ino)
        # A sibling may change parent timestamps; parent identity must stay bound.
        (restored.parent / 'unrelated-sibling').write_bytes(b'other work')
        self.assertEqual(cache.frozen_runtime_context(root, restored, seal_sha, restored_dump=binding), original)
        self.assertEqual(held, {name: (root / name).read_bytes() for name in held})

    def test_restoration_requires_original_compressed_hash_size_and_regular_path(self):
        for kind in ('changed-bytes', 'size', 'claimed-digest', 'claimed-size', 'mode', 'path-spelling', 'symlink', 'parent-symlink'):
            with self.subTest(kind=kind):
                root, old, restored, descriptor, seal_sha, original, held = self.restored_fixture()
                if kind == 'changed-bytes': restored.write_bytes(b'X' * descriptor['bytes'])
                elif kind == 'size': restored.write_bytes(b'truncated')
                elif kind == 'claimed-digest': descriptor['sha256'] = '0' * 64
                elif kind == 'claimed-size': descriptor['bytes'] += 1
                elif kind == 'mode': descriptor['mode'] = 0o600
                elif kind == 'path-spelling': descriptor['path'] = str(restored.parent) + '//' + restored.name
                elif kind == 'symlink':
                    actual = restored.with_suffix('.actual'); restored.rename(actual); restored.symlink_to(actual)
                else:
                    parent = self.base / ('link-' + restored.name); parent.symlink_to(restored.parent, target_is_directory=True)
                    descriptor['path'] = str(parent / restored.name)
                with self.assertRaises((ValueError, OSError)):
                    cache.restored_dump_binding(root, descriptor, seal_sha)
                self.assertEqual(held, {name: (root / name).read_bytes() for name in held})

    def test_restored_binding_rejects_replacement_foreign_context_and_mutable_proof(self):
        root, old, restored, descriptor, seal_sha, original, held = self.restored_fixture()
        binding = cache.restored_dump_binding(root, descriptor, seal_sha)
        for proof in (dict(path=str(restored)), list(binding), tuple(binding)):
            with self.subTest(proof=type(proof).__name__), self.assertRaises(ValueError):
                cache.frozen_runtime_context(root, restored, seal_sha, restored_dump=proof)
        other = restored.with_suffix('.other'); other.write_bytes(restored.read_bytes())
        with self.assertRaises(ValueError):
            cache.frozen_runtime_context(root, other, seal_sha, restored_dump=binding)
        replacement = restored.with_suffix('.new'); replacement.write_bytes(restored.read_bytes()); replacement.chmod(0o644)
        replacement.replace(restored)
        with self.assertRaises(ValueError):
            cache.frozen_runtime_context(root, restored, seal_sha, restored_dump=binding)
        with self.assertRaises(ValueError):
            cache.restored_dump_binding(root, descriptor, seal_sha, previous=binding)
        fresh = cache.restored_dump_binding(root, descriptor, seal_sha)
        self.assertNotEqual(fresh, binding)
        self.assertEqual(cache.frozen_runtime_context(root, restored, seal_sha, restored_dump=fresh), original)
        other_root, _, _, _, other_sha, _, _ = self.restored_fixture()
        with self.assertRaises(ValueError):
            cache.frozen_runtime_context(other_root, restored, other_sha, restored_dump=fresh)
        self.assertEqual(held, {name: (root / name).read_bytes() for name in held})

    def test_restoration_hash_race_and_final_source_guard_preserve_failures(self):
        for kind in ('hash-replace', 'hash-write', 'hash-error', 'hash-selection', 'late-replace', 'index', 'receipt', 'seal', 'worker'):
            with self.subTest(kind=kind):
                root, old, restored, descriptor, seal_sha, original, held = self.restored_fixture()
                digest = cache.stable_file_digest
                def replaced():
                    new = restored.with_suffix('.new'); new.write_bytes(restored.read_bytes()); new.chmod(0o644); new.replace(restored)
                if kind.startswith('hash-'):
                    def changed(path, **options):
                        result = digest(path, **options)
                        if Path(path) == restored:
                            if kind == 'hash-error': raise MemoryError('restoration allocation')
                            if kind == 'hash-replace': replaced()
                            elif kind == 'hash-selection': descriptor['sha256'] = '0' * 64
                            else: restored.write_bytes(b'X' * descriptor['bytes'])
                        return result
                    with mock.patch.object(cache, 'stable_file_digest', side_effect=changed), self.assertRaises(MemoryError if kind == 'hash-error' else ValueError):
                        cache.restored_dump_binding(root, descriptor, seal_sha)
                    continue
                binding = cache.restored_dump_binding(root, descriptor, seal_sha)
                if kind == 'late-replace':
                    source = cache._completed_source_binding
                    def changed(*args, **kwargs):
                        result = source(*args, **kwargs); replaced(); return result
                    with mock.patch.object(cache, '_completed_source_binding', side_effect=changed), self.assertRaises(ValueError):
                        cache.frozen_runtime_context(root, restored, seal_sha, restored_dump=binding)
                else:
                    name = {'index':'page-index.tsv', 'receipt':'extraction-source.json', 'seal':cache.COMPLETED_EXPANDER, 'worker':'dict-bundle-expander'}[kind]
                    path = root / name; path.write_bytes(path.read_bytes() + b'changed')
                    with self.assertRaises((ValueError, OSError)):
                        cache.frozen_runtime_context(root, restored, seal_sha, restored_dump=binding)
                self.assertFalse(old.exists())




class SealedFrontendBuildPolicyTests(SealedFrontendTests):
    def policy_sources(self):
        # These real revisions differ only in build changes the policy recognizes.
        # Later changes to the producer graph must remain independently rejectable.
        root = Path(__file__).with_name('testdata') / 'sealed-frontend-build-policy'
        def source(revision, expected):
            with gzip.open(root / (revision + '.zig.gz'), 'rb') as stream:
                raw = stream.read()
            self.assertEqual(expected, cache.hashlib.sha256(raw).hexdigest())
            return raw.decode('utf-8')

        old = source('c44f14b6', 'd8923f8afb3b2b87fd871d34549893e65b838e6940a17088cfd2e3df3c6f77c8')
        current = source('0b497365', '7eb2e72ccfa2e48ba2efda32f7f97a917aaec6acd29f629d22faff9dff3e1a2b')
        return old, current

    def test_writer_dependency_change_cannot_reuse_an_older_producer_seal(self):
        old, current = self.policy_sources()
        anchor = '    blob_build_exe.root_module.addImport("namespace_registry", namespace_registry_mod);\n'
        added = '    blob_build_exe.root_module.addImport("missing_dependency", missing_dependency_mod);\n'
        self.assertEqual(1, current.count(anchor))
        changed = current.replace(anchor, anchor + added, 1)
        self.assertEqual('2f07dcb0e7e26e2acd6646a4df1e8cc3f91e444f9f9a8bb138ae550c579c8527',
                         cache.hashlib.sha256(changed.encode()).hexdigest())  # 6748b11a
        with mock.patch.object(self, 'policy_sources', return_value=(old, changed)):
            root, seal, _, _, reference, _, _, _ = self.policy_prepared()
            with self.assertRaisesRegex(ValueError, 'native producer graph changed'):
                self.selected(reference)
            self.assertEqual(seal, cache.read_marker(root / cache.COMPLETED_EXPANDER))

    def policy_prepared(self):
        old, current = self.policy_sources()
        build = self.project / 'build.zig'; build.write_text(old)
        root, dump, snapshots, seal, path, data, reference = self.prepared()
        original = cache._frontend_reference(data['roles'])
        roles = json.loads(json.dumps(original))
        build.write_text(current)
        role = roles['dict-bundle-build']; role['source_root'] = str(self.project)
        role['dependencies']['runtime_source:build.zig'] = self.reference(build)
        proof = dict(version=1, projection='qualification-scheduler-v1', original_source=old,
            original_build=[len(old.encode()), cache.hashlib.sha256(old.encode()).hexdigest()],
            current_build=[len(current.encode()), cache.hashlib.sha256(current.encode()).hexdigest()])
        proof_path = self.base / 'build-policy.json'
        descriptor = self.write_json(proof_path, dict(build_policy_correspondence=proof))
        role['layout_source_correspondence'] = descriptor
        data['roles'] = self.write_json(self.base / 'policy-current-roles.json', roles)
        data['sealed_frontend']['layout_sources'] = [descriptor]
        reference = self.write_json(path, data)
        return root, seal, path, data, reference, roles, proof_path, proof

    def test_build_policy_real_scheduler_transition_keeps_original_seal_and_native_objects(self):
        root, seal, path, data, reference, roles, proof_path, proof = self.policy_prepared()
        selected = self.selected(reference)
        self.assertEqual(seal, selected[3])
        self.assertEqual(data['sealed_frontend']['layout_sources'], selected[0]['layout_sources'])
        original = cache._frontend_reference(cache._frontend_reference(
            data['sealed_frontend']['preparation_result'])['role_map'])
        for name, descriptor in original['dict-bundle-build']['dependencies'].items():
            if name != 'runtime_source:build.zig':
                self.assertEqual(descriptor, roles['dict-bundle-build']['dependencies'][name])
        self.assertEqual(seal, cache.read_marker(root / cache.COMPLETED_EXPANDER))
        old, current = self.policy_sources()
        self.assertEqual(cache._native_build_policy_projection(old), cache._native_build_policy_projection(current))
        # The real canonical build may already contain either exact install
        # selection. Exercise exactly one tools block, never a duplicate graph.
        plain = current.replace(cache._INSTALL_ONLY_SOURCE + cache._RUNTIME_ONLY_SOURCE, '', 1)
        plain = plain.replace(cache._INSTALL_ONLY_SOURCE, '', 1)
        self.assertEqual(cache._native_build_policy_projection(current), cache._native_build_policy_projection(
            plain.replace('    const worker_object = bundleWorkerObject(b);\n',
                          '    const worker_object = bundleWorkerObject(b);\n' + cache._INSTALL_ONLY_SOURCE, 1)))

    def test_exact_verifier_target_keeps_real_sealed_frontend_and_native_objects(self):
        old,current=self.policy_sources()
        self.assertEqual(cache._native_build_policy_projection(old),cache._native_build_policy_projection(current))
        root,seal,path,data,reference,roles,proof_path,proof=self.policy_prepared()
        self.assertEqual(seal,self.selected(reference)[3])
        self.assertEqual(seal,cache.read_marker(root/cache.COMPLETED_EXPANDER))
        original=cache._frontend_reference(cache._frontend_reference(data['sealed_frontend']['preparation_result'])['role_map'])
        for key,value in original['dict-bundle-build']['dependencies'].items():
            if key!='runtime_source:build.zig':self.assertEqual(value,roles['dict-bundle-build']['dependencies'][key])


    def test_altered_verifier_target_edges_or_native_settings_refuse(self):
        old,current=self.policy_sources()
        mutations=[
            ('target','b.step("prepare-blob-verify",','b.step("foreign-verify",'),
            ('artifact','if (artifact == blob_verify_exe) prepare_blob_verify','if (artifact == blob_build_exe) prepare_blob_verify'),
            ('dependency','prepare_blob_verify.dependOn(&install.step);','prepare_blob_verify.dependOn(&llvm_exe.step);'),
            ('extra dependency','prepare_blob_verify.dependOn(&install.step);','prepare_blob_verify.dependOn(&install.step); prepare_blob_verify.dependOn(&module_extract_exe.step);'),
            ('missing declaration','    const prepare_blob_verify = b.step("prepare-blob-verify", "Prepare only the existing native blob verification tool");\n',''),
            ('missing edge','        if (artifact == blob_verify_exe) prepare_blob_verify.dependOn(&install.step);\n',''),
            ('duplicate graph','    const prepare_blob_verify = b.step("prepare-blob-verify", "Prepare only the existing native blob verification tool");','    const prepare_blob_verify = b.step("prepare-blob-verify", "Prepare only the existing native blob verification tool"); const prepare_blob_verify2 = b.step("prepare-blob-verify", "Prepare only the existing native blob verification tool");'),
            ('native mode','.strip = true','.strip = false'),
        ]
        for label,needle,replacement in mutations:
            with self.subTest(label=label):
                self.assertIn(needle,current);wrong=current.replace(needle,replacement,1)
                try:projection=cache._native_build_policy_projection(wrong)
                except ValueError:pass
                else:self.assertNotEqual(cache._native_build_policy_projection(old),projection)
                with mock.patch.object(self,'policy_sources',return_value=(old,wrong)):
                    root,seal,path,data,reference,roles,proof_path,proof=self.policy_prepared()
                    with self.assertRaises(ValueError):self.selected(reference)
                    self.assertEqual(seal,cache.read_marker(root/cache.COMPLETED_EXPANDER))


    def test_runtime_only_install_reuses_original_worker_graph_and_refuses_other_edges(self):
        old, current = self.policy_sources()
        plain = current.replace(cache._INSTALL_ONLY_SOURCE + cache._RUNTIME_ONLY_SOURCE, '', 1)
        plain = plain.replace(cache._INSTALL_ONLY_SOURCE, '', 1)
        anchor = '    const worker_object = bundleWorkerObject(b);\n'
        self.assertEqual(plain.count(anchor), 1)
        exact = cache._INSTALL_ONLY_SOURCE + cache._RUNTIME_ONLY_SOURCE
        runtime = plain.replace(anchor, anchor + exact, 1)
        baseline = cache._native_build_policy_projection(old)
        self.assertEqual(baseline, cache._native_build_policy_projection(runtime))
        # Run the maintained selection on this proposed real build source too;
        # a token-only positive is not the original role/identity guard.
        with mock.patch.object(self, 'policy_sources', return_value=(old, runtime)):
            root, seal, path, data, reference, roles, proof_path, proof = self.policy_prepared()
            self.assertEqual(seal, self.selected(reference)[3])
            self.assertEqual(seal, cache.read_marker(root / cache.COMPLETED_EXPANDER))
        for label, wrong in (
            ('LLVM dependency', cache._RUNTIME_ONLY_SOURCE.replace('&install_worker_object.step', '&llvm_exe.step')),
            ('extractor dependency', cache._RUNTIME_ONLY_SOURCE.replace('&install_worker_object.step', '&module_extract_exe.step')),
            ('different target', cache._RUNTIME_ONLY_SOURCE.replace('prepare-expander-runtime', 'foreign-runtime')),
            ('duplicate target', cache._RUNTIME_ONLY_SOURCE * 2),
            ('missing shared install', cache._RUNTIME_ONLY_SOURCE),
        ):
            with self.subTest(label=label):
                block = wrong if label == 'missing shared install' else cache._INSTALL_ONLY_SOURCE + wrong
                changed = plain.replace(anchor, anchor + block, 1)
                try: projected = cache._native_build_policy_projection(changed)
                except ValueError: continue
                self.assertNotEqual(baseline, projected)
        moved = plain.replace('    const target = b.standardTargetOptions(.{});',
            exact + '    const target = b.standardTargetOptions(.{});', 1)
        with self.assertRaises(ValueError): cache._native_build_policy_projection(moved)

    def test_build_policy_native_flags_functions_graph_and_scheduler_changes_refuse(self):
        old, current = self.policy_sources()
        mutations = (
            ('worker flags', '.strip = true', '.strip = false'),
            ('worker helper', 'fn bundleWorkerObject(', 'fn foreignWorkerObject('),
            ('leaf helper', 'fn bundleValueLeafObject(', 'fn foreignLeafObject('),
            ('module import', 'fn workerModule(', 'fn foreignWorkerModule('),
            ('namespace graph', 'fn namespaceRegistryModule(', 'fn foreignNamespaceRegistryModule('),
            ('scheduler semantics', 'fn claimQualificationMemory(', 'fn foreignQualificationMemory('),
            ('install graph', '    const target = b.standardTargetOptions(.{});',
                cache._INSTALL_ONLY_SOURCE.replace('worker_object.getEmittedBin()', 'module_extract_exe.getEmittedBin()') +
                '    const target = b.standardTargetOptions(.{});'),
        )
        # A real worker link dependency must never become an aggregate-only
        # qualification edge, even if the test aggregate is moved into scope.
        declaration = '    const test_step = b.step("test", "Run bundle encoder, data reader, Lua, and tooling tests");\n'
        migrated = current.replace(declaration, '', 1).replace(
            '    const target = b.standardTargetOptions(.{});',
            declaration + '    const target = b.standardTargetOptions(.{});', 1).replace(
            'link.step.dependOn(&cli_install.step);',
            'addTestOrder(test_step, &link.step, &cli_install.step, test_step_memory != 0);', 1)
        with self.assertRaises(ValueError): cache._native_build_policy_projection(migrated)
        # Even the exact install-only block is accepted only beside the original
        # worker producer and its unchanged pipeline-path registration.
        misplaced = current.replace('    const target = b.standardTargetOptions(.{});',
            cache._INSTALL_ONLY_SOURCE + '    const target = b.standardTargetOptions(.{});', 1)
        with self.assertRaises(ValueError): cache._native_build_policy_projection(misplaced)
        baseline = cache._native_build_policy_projection(old)
        for label, needle, replacement in mutations:
            with self.subTest(label=label):
                self.assertIn(needle, current)
                changed = current.replace(needle, replacement, 1)
                try: projected = cache._native_build_policy_projection(changed)
                except ValueError: continue
                self.assertNotEqual(baseline, projected)

    def test_build_policy_missing_foreign_and_changed_source_authorities_refuse(self):
        root, seal, path, data, reference, roles, proof_path, proof = self.policy_prepared()
        original_data = json.loads(json.dumps(data)); original_roles = json.loads(json.dumps(roles))
        for label in ('missing', 'old hash', 'current hash', 'path', 'duplicate', 'wrong closure', 'native leaf'):
            with self.subTest(label=label):
                data = json.loads(json.dumps(original_data)); roles = json.loads(json.dumps(original_roles))
                chosen = json.loads(json.dumps(proof)); role = roles['dict-bundle-build']
                if label == 'old hash': chosen['original_source'] += '\n// foreign bytes\n'
                if label == 'current hash': chosen['current_build'][1] = '0' * 64
                descriptor = self.write_json(proof_path, dict(build_policy_correspondence=chosen))
                role['layout_source_correspondence'] = descriptor
                data['sealed_frontend']['layout_sources'] = [descriptor]
                if label == 'missing':
                    role.pop('layout_source_correspondence'); data['sealed_frontend']['layout_sources'] = []
                if label == 'duplicate':
                    # Distinct authenticated records cannot choose two policies.
                    another = self.write_json(self.base / 'second-policy.json', dict(build_policy_correspondence=chosen))
                    roles['second-layout-proof'] = dict(layout_source_correspondence=another)
                    data['sealed_frontend']['layout_sources'].append(another)
                if label == 'path': role['source_root'] = str(self.base / 'foreign-project')
                if label == 'native leaf': role['dependencies']['value_leaf_bc']['sha256'] = '0' * 64
                if label == 'wrong closure':
                    closure = cache._frontend_reference(data['sealed_frontend']['preparation_closure'])
                    closure['source_after'] = False
                    data['sealed_frontend']['preparation_closure'] = self.write_json(self.base / 'bad-closure.json', closure)
                data['roles'] = self.write_json(self.base / 'policy-current-roles.json', roles)
                with self.assertRaises(ValueError): self.selected(self.write_json(path, data))
        # Byte replacement after descriptor issuance is refused by exact digest.
        self.write_json(proof_path, dict(build_policy_correspondence=proof))
        self.write_json(self.base / 'policy-current-roles.json', original_roles)
        (self.project / 'build.zig').write_text(proof['original_source'])
        with self.assertRaises(ValueError): self.selected(self.write_json(path, original_data))

    def test_build_policy_producer_transition_requires_both_exact_policy_digests(self):
        root, seal, path, data, reference, roles, proof_path, proof = self.policy_prepared()
        selected = self.selected(reference)
        original, current = seal['identity']['producer'], selected[5]
        binding = dict(original=proof['original_build'], current=proof['current_build'])
        cache._frontend_producer_transition(original, current, build_policy=binding)
        with self.assertRaises(ValueError): cache._frontend_producer_transition(original, current)
        for key in ('original', 'current'):
            changed = json.loads(json.dumps(binding)); changed[key][1] = '0' * 64
            with self.subTest(key=key), self.assertRaises(ValueError):
                cache._frontend_producer_transition(original, current, build_policy=changed)




class SealedFrontendRestoredSourceTests(SealedFrontendTests):
    def restored_prepared(self, *, relocated=False):
        root, dump, snapshots, seal, path, data, reference = self.prepared()
        expected = cache._frontend_extraction_identity(self.graph['extractor'], cache.sha256(dump), 'b' * 64, root)
        self.assertEqual(0, cache.publish(self.root, expected, root))
        raw = dump.read_bytes(); retired = dump.with_name(dump.name + '.original-inode')
        dump.rename(retired)
        if relocated:
            dump = self.base / ('restored-input-' + str(self.sequence)) / 'pages.xml.zst'
            dump.parent.mkdir()
        dump.write_bytes(raw)
        self.assertNotEqual(retired.stat().st_ino, dump.stat().st_ino)
        chosen = dict(dump=self.reference(dump), custody=json.loads(json.dumps(cache._restored_dump_custody(dump))))
        data['sealed_frontend']['restored_dump'] = chosen
        reference = self.write_json(path, data)
        return root, dump, snapshots, seal, path, data, reference

    def frontend_calls(self):
        original = cache._frontend_selection
        def eligibility(ref, graph, **kwargs):
            with mock.patch.object(cache, '__file__', str(self.project / 'tools/extraction_cache.py')):
                return original(ref, graph, validate_roles=False,
                    producer_observation=kwargs.get('producer_observation'),
                    restored_dump=kwargs.get('restored_dump'))
        return mock.patch.object(cache, '_frontend_selection', side_effect=eligibility)

    def restored_output(self, data, snapshots):
        output = Path(data['workspace']) / 'expander' / '.bundle-expander'
        (output / 'llvm').mkdir(parents=True)
        for name, source in snapshots.items():
            if source is not None: (output / name).symlink_to(source)
        cache.shutil.copyfile(self.graph['leaf'], output / 'llvm/value_leaf.bc')
        return output

    def test_frontend_restored_dump_runs_real_probe_and_seals_original_source_identity(self):
        self.run_restored_probe_and_seal(relocated=False)

    def test_frontend_relocated_dump_runs_real_probe_and_seals_original_source_identity(self):
        self.run_restored_probe_and_seal(relocated=True)

    def run_restored_probe_and_seal(self, *, relocated):
        root, dump, snapshots, seal, path, data, reference = self.restored_prepared(relocated=relocated)
        if relocated:
            self.assertNotEqual(str(dump), data["dump"]["path"])
            self.assertFalse(Path(data["dump"]["path"]).exists())
        original_seal = (root / cache.COMPLETED_EXPANDER).read_bytes()
        original_receipt = (root / 'extraction-source.json').read_bytes()
        with self.assertRaises(ValueError): cache.completed_source_binding(root, dump)
        selected = self.selected(reference)
        binding = selected[0]['_restored_dump_binding']
        self.assertEqual(seal['identity']['source'], cache._frontend_completed_source(root, dump, binding))
        output = self.restored_output(data, snapshots)
        with self.frontend_calls(), mock.patch.object(cache, 'validate', wraps=cache.validate) as validation:
            self.assertEqual(0, cache.probe_sealed_frontend(self.root, self.graph['extractor'], cache.sha256(dump),
                'b' * 64, output, dump, self.graph, reference))
        self.assertEqual(1, validation.call_count)
        self.assertEqual(original_receipt, (output / 'extraction-source.json').read_bytes())
        for name, size, digest in seal['link']['ordered_objects']:
            self.assertEqual([size, digest], cache.stable_file_digest(output / 'llvm' / name))
        self.assertFalse((output / cache.COMPLETED_EXPANDER).exists())
        # Reproduce only the existing driver's post-link file moves with the
        # fixture's already-observed native bytes; no compiler/link process runs.
        (output / 'llvm/program.meta').rename(output / 'lua-program.meta')
        (output / 'llvm/batch-plan.tsv').rename(output.parent / 'compile-plan.tsv')
        (output / 'llvm/compile-plan.tsv').rename(output.parent / 'module-compile-plan.tsv')
        cache.shutil.copyfile(root / 'dict-bundle-expander', output / 'dict-bundle-expander')
        (output / 'llvm/module-objects.rsp').write_text(''.join(json.dumps(str(output / 'llvm' / name)) + '\n'
            for name, _, _ in seal['link']['ordered_objects']))
        (output / '.incomplete').write_bytes(b'building'); (output.parent / '.incomplete').write_bytes(b'linking')
        digest = cache.stable_file_digest
        def count_dump(*args, **kwargs): return digest(*args, **kwargs)
        with self.frontend_calls(), mock.patch.object(cache, 'stable_file_digest', side_effect=count_dump) as reads:
            self.assertEqual(0, cache.seal_completed_expander(output, dump, cache.sha256(dump), 'b' * 64,
                self.graph, snapshots, frontend_reference=reference))
        dump_reads = [call for call in reads.call_args_list if Path(call.args[0]) == dump]
        self.assertEqual(1, len(dump_reads))
        produced = cache.read_marker(output / cache.COMPLETED_EXPANDER)
        self.assertEqual(seal['identity']['source'], produced['identity']['source'])
        self.assertEqual(seal['identity']['verified_input'], produced['identity']['verified_input'])
        self.assertEqual(seal['link']['ordered_objects'], produced['link']['ordered_objects'])
        self.assertEqual(original_receipt, (output / 'extraction-source.json').read_bytes())
        self.assertEqual(original_seal, (root / cache.COMPLETED_EXPANDER).read_bytes())
        self.assertFalse(any((output / 'llvm').glob('module_batch*.bc')))

    def test_frontend_relocated_dump_refuses_cli_disagreement_and_late_parent_replacement(self):
        root, dump, snapshots, seal, path, data, reference = self.restored_prepared(relocated=True)
        binding = self.selected(reference)[0]['_restored_dump_binding']
        output = self.restored_output(data, snapshots)
        with self.frontend_calls(), mock.patch.object(cache, 'validate', wraps=cache.validate) as validation:
            with self.assertRaisesRegex(ValueError, 'dump/index selection changed'):
                cache.probe_sealed_frontend(self.root, self.graph['extractor'], cache.sha256(dump),
                    'b' * 64, output, Path(data['dump']['path']), self.graph, reference)
        self.assertEqual(0, validation.call_count)
        raw = dump.read_bytes()
        parent = dump.parent
        parent.rename(parent.with_name(parent.name + '.selected-parent'))
        parent.mkdir(); dump.write_bytes(raw)
        with self.assertRaises(ValueError): self.selected(reference)
        with self.assertRaises(ValueError): cache._frontend_completed_source(root, dump, binding)

    def test_frontend_restored_selection_refuses_wrong_bytes_size_custody_source_and_foreign_proof(self):
        for case in ('hash', 'size', 'custody', 'path', 'null', 'source receipt', 'index', 'seal'):
            with self.subTest(case=case):
                root, dump, snapshots, seal, path, data, reference = self.restored_prepared()
                chosen = data['sealed_frontend']['restored_dump']
                if case == 'hash': chosen['dump']['sha256'] = '0' * 64
                elif case == 'size': chosen['dump']['bytes'] += 1
                elif case == 'custody': chosen['custody'][0][1] += 1
                elif case == 'path':
                    foreign = self.base / ('foreign-dump-' + str(self.sequence)); foreign.write_bytes(dump.read_bytes())
                    chosen['dump'] = self.reference(foreign)
                    # A path change without its selected physical custody must refuse.
                elif case == 'null': data['sealed_frontend']['restored_dump'] = None
                elif case == 'source receipt': (root / 'extraction-source.json').write_bytes(b'{}')
                elif case == 'index': (root / 'page-index.tsv').write_bytes(b'foreign index')
                else: (root / cache.COMPLETED_EXPANDER).write_bytes(b'{}')
                reference = self.write_json(path, data)
                with self.assertRaises((ValueError, KeyError)): self.selected(reference)
                self.assertFalse((Path(data['workspace']) / 'expander/.bundle-expander' / cache.COMPLETED_EXPANDER).exists())

    def test_frontend_restored_dump_binding_refuses_late_inode_and_index_changes(self):
        for case in ('inode', 'bytes', 'index', 'foreign binding', 'raw JSON'):
            with self.subTest(case=case):
                root, dump, snapshots, seal, path, data, reference = self.restored_prepared()
                binding = self.selected(reference)[0]['_restored_dump_binding']
                original = dump.read_bytes()
                if case == 'inode':
                    dump.rename(dump.with_name(dump.name + '.selected-inode')); dump.write_bytes(original)
                elif case == 'bytes': dump.write_bytes(b'changed bytes')
                elif case == 'index': (root / 'page-title-index.bin').write_bytes(b'changed index')
                elif case == 'foreign binding':
                    binding = cache._RestoredDumpBinding((str(self.base / 'foreign-root'), *binding[1:]))
                else: binding = data['sealed_frontend']['restored_dump']
                with self.assertRaises(ValueError): cache._frontend_completed_source(root, dump, binding)
                if case in ('inode', 'bytes', 'index'):
                    with self.assertRaises(ValueError): self.selected(reference)
                with self.assertRaises(ValueError): cache._frontend_completed_source(root, dump, None)



class ExtractionMetadataRefreshTests(unittest.TestCase):
    setUp = CompletedExpanderTests.setUp
    fixture = CompletedExpanderTests.fixture
    call = CompletedExpanderTests.call
    def custody_fixture(self):
        root, dump, _ = self.fixture()
        seal_path = root / cache.COMPLETED_EXPANDER
        original = seal_path.read_bytes(); seal = json.loads(original)
        names = sorted([*cache.FILES, 'modules/123.lua'])
        expected = dict(version=4, extractor_args=list(cache.EXTRACTOR_ARGS),
            dump_sha256='a'*64, index_sha256='b'*64,
            namespace_registry_sha256='f'*64, transclusion_redirects_sha256=None,
            page_redirects_sha256=None, unicode_case={'libraries': []},
            tool={'extractor_sha256': 'c'*64, 'libraries': []})
        key = cache.hashlib.sha256(json.dumps(expected, sort_keys=True).encode()).hexdigest()
        backing = self.base / ('extraction-custody-'+str(self.sequence)) / key
        (backing/'modules').mkdir(parents=True)
        for name in names: cache._owned_extraction_link(root/name, backing/name)
        assets = [r for r in seal['identity']['assets'] if r[0] in names]
        manifest = backing/'.complete.json'
        manifest.write_text(json.dumps(dict(asset_ownership=cache.EXTRACTION_OWNERSHIP,
            identity=expected, assets=assets)))
        selection = dict(original_seal_sha256=cache.hashlib.sha256(original).hexdigest(),
            cache_manifest=dict(path=str(manifest), bytes=manifest.stat().st_size, sha256=cache.sha256(manifest)), names=names)
        return root, dump, backing, original, selection

    def test_extraction_custody_exact_alias_bytes_once_and_seal_unchanged(self):
        root, dump, backing, original, selection = self.custody_fixture()
        digest = selection['original_seal_sha256']
        with self.assertRaises(ValueError): cache.frozen_runtime_context(root,dump,digest)
        original_digest = cache.stable_file_digest; reads=[]
        def counted(path, **kwargs):
            if Path(path).is_relative_to(root) and str(Path(path).relative_to(root)) in selection['names']:reads.append(str(Path(path).relative_to(root)))
            return original_digest(path, **kwargs)
        with mock.patch.object(cache, 'stable_file_digest', side_effect=counted), mock.patch.object(cache, 'validate_extraction_completion', wraps=cache.validate_extraction_completion) as complete:
            first=cache.frozen_runtime_context(root,dump,digest,extraction_metadata_refresh=selection)
            second=cache.frozen_runtime_context(root,dump,digest,extraction_metadata_refresh=selection)
            self.assertEqual(selection['names'], sorted(reads));self.assertEqual(1,complete.call_count)
        self.assertEqual(first,second)
        self.assertEqual(original,(root/cache.COMPLETED_EXPANDER).read_bytes())
        restored=json.loads(json.dumps(first));restored['runtime_stamps']['assets']=json.loads(original)['runtime_stamps']['assets']
        self.assertEqual(json.loads(original),restored)

    def test_extraction_custody_rejects_changed_bytes_aliases_selection_and_other_assets(self):
        for change in ('body-restored-mtime','mode','inode','alias-copy','alias-symlink','source-symlink','missing-name','manifest','manifest-digest','unselected-worker','provider-update'):
            with self.subTest(change=change):
                root,dump,backing,original,selection=self.custody_fixture();source=root/'modules/123.lua';alias=backing/'modules/123.lua';before=source.stat()
                if change=='body-restored-mtime':source.write_bytes(b'return 2');cache.os.utime(source,ns=(before.st_atime_ns,before.st_mtime_ns))
                elif change=='mode':source.chmod(0o600)
                elif change=='inode':
                    fresh=root/'modules/new';fresh.write_bytes(source.read_bytes());cache.os.utime(fresh,ns=(before.st_atime_ns,before.st_mtime_ns));fresh.replace(source)
                elif change=='alias-copy':alias.unlink();alias.write_bytes(source.read_bytes())
                elif change=='alias-symlink':alias.unlink();alias.symlink_to(source)
                elif change=='source-symlink':source.unlink();source.symlink_to(alias)
                elif change=='missing-name':selection['names'].remove('modules/123.lua')
                elif change=='manifest':(backing/'.complete.json').write_text('{}')
                elif change=='manifest-digest':
                    p=backing/'.complete.json';record=json.loads(p.read_text());next(r for r in record['assets'] if r[0]=='modules/123.lua')[2]='0'*64;p.write_text(json.dumps(record));selection['cache_manifest'].update(bytes=p.stat().st_size,sha256=cache.sha256(p))
                elif change=='unselected-worker':(root/'dict-bundle-expander').chmod(0o600)
                with self.assertRaises((ValueError,OSError)):
                    cache.frozen_runtime_context(root,dump,selection['original_seal_sha256'],extraction_metadata_refresh=selection,provider_update=change=='provider-update')
                self.assertEqual(original,(root/cache.COMPLETED_EXPANDER).read_bytes())

    def test_extraction_custody_rejects_alias_mutation_during_and_after_hash(self):
        for after in (False,True):
            with self.subTest(after=after):
                root,dump,backing,original,selection=self.custody_fixture();digest=selection['original_seal_sha256']
                if after:cache.frozen_runtime_context(root,dump,digest,extraction_metadata_refresh=selection)
                target=backing/'modules/123.lua'
                def mutate():
                    body=target.read_bytes();target.unlink();target.write_bytes(body)
                if after:
                    mutate()
                    with self.assertRaises(ValueError):cache.frozen_runtime_context(root,dump,digest,extraction_metadata_refresh=selection)
                else:
                    digest_file=cache.stable_file_digest;fired=False
                    def mutating(path,**kwargs):
                        nonlocal fired
                        value=digest_file(path,**kwargs)
                        if not fired and Path(path)==root/selection['names'][-1]:fired=True;mutate()
                        return value
                    with mock.patch.object(cache,'stable_file_digest',side_effect=mutating):
                        with self.assertRaises(ValueError):cache.frozen_runtime_context(root,dump,digest,extraction_metadata_refresh=selection)
                    self.assertTrue(fired)


class RestoredIndexCustodyTests(unittest.TestCase):
    setUp = CompletedExpanderTests.setUp
    fixture = CompletedExpanderTests.fixture
    call = CompletedExpanderTests.call

    def restored_fixture(self, *, restore=True, malformed=False):
        root, dump, snapshots = self.fixture(ready=False)
        page = b'# dict-page-index-v3\tmultistream-zstd\n0\t0\t10\tTemplate:fixture\n'
        (root / 'page-index.tsv').write_bytes(page)
        header = b'DPTIDX01' + b''.join(n.to_bytes(8, 'little') for n in (2, 8, 1, 1, len(page))) + bytes(16)
        (root / 'page-title-index.bin').write_bytes(header + bytes(128))
        (root / 'extraction-completion.json').write_text(json.dumps(dict(
            schema='wikidict.extraction-completion.v1', version=1,
            expected_stream_count=1, consumed_stream_count=1, pages=1)))
        receipt = root / 'extraction-source.json'
        value = json.loads(receipt.read_bytes())
        value['indexes'] = [cache._receipt_identity(root / n, index=True) for n in (*cache.RESTORED_INDEX_NAMES, 'dump-streams.tsv')]
        receipt.write_text(json.dumps(value))
        identity = dict(version=4, extractor_args=list(cache.EXTRACTOR_ARGS),
            dump_sha256=cache.sha256(dump), index_sha256='b'*64,
            namespace_registry_sha256='f'*64, transclusion_redirects_sha256=None,
            page_redirects_sha256=None, unicode_case={'libraries': []},
            tool={'extractor_sha256': 'c'*64, 'libraries': []})
        key = cache.hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()
        backing = self.base / ('restored-index-cache-' + str(self.sequence)) / key
        (backing / 'modules').mkdir(parents=True)
        names = sorted([*cache.FILES, 'modules/123.lua'])
        for name in names:
            cache._owned_extraction_link(root / name, backing / name)
        self.assertEqual(0, self.call('seal-expander', root, dump, snapshots, dump_sha=cache.sha256(dump)))
        cache.shutil.rmtree(root / 'llvm')
        (root / '.incomplete').unlink(); (root.parent / '.incomplete').write_bytes(b'expander ready')
        marker = root / cache.COMPLETED_EXPANDER
        seal = json.loads(marker.read_bytes())
        if malformed:
            # Authenticate a legacy malformed title header to ensure the new
            # route validates format as well as equal original hashes.
            title = root / 'page-title-index.bin'; before = title.stat()
            body = title.read_bytes()
            title.write_bytes(body[:8] + (1).to_bytes(8, 'little') + body[16:] if malformed == 'kind' else b'INVALID!' + body[8:])
            cache.os.utime(title, ns=(before.st_atime_ns, before.st_mtime_ns))
            seal['identity']['assets'] = [[n, *cache.stable_file_digest(root / n)] if n == title.name else row
                for row in seal['identity']['assets'] for n in [row[0]]]
            seal['runtime_stamps']['assets'][title.name] = list(cache._full_stamp(title.stat()))
            marker.write_text(json.dumps(seal))
        original = marker.read_bytes()
        manifest = backing / '.complete.json'
        manifest.write_text(json.dumps(dict(asset_ownership=cache.EXTRACTION_OWNERSHIP,
            identity=identity, assets=[r for r in seal['identity']['assets'] if r[0] in names])))
        selection = dict(original_seal_sha256=cache.sha256(marker),
            cache_manifest=dict(path=str(manifest), bytes=manifest.stat().st_size, sha256=cache.sha256(manifest)),
            names=list(cache.RESTORED_INDEX_NAMES))
        if restore:
            for name in cache.RESTORED_INDEX_NAMES:
                source = root / name; before = source.stat()
                fresh = self.base / ('fresh-' + str(self.sequence) + '-' + name)
                fresh.write_bytes(source.read_bytes()); fresh.chmod(before.st_mode & 0o7777)
                cache.os.utime(fresh, ns=(before.st_atime_ns, before.st_mtime_ns))
                (backing / name).unlink(); fresh.replace(source); cache.os.link(source, backing / name)
                self.assertNotEqual(before.st_ino, source.stat().st_ino)
        return root, dump, backing, original, selection

    def test_restored_pair_reuses_original_context_with_one_hash_and_no_rewrite(self):
        root, dump, backing, original, selection = self.restored_fixture()
        sha = selection['original_seal_sha256']; receipt = (root / 'extraction-source.json').read_bytes()
        with self.assertRaises(ValueError): cache.frozen_runtime_context(root, dump, sha)
        reads = []; digest = cache.stable_file_digest
        def counted(path, **kwargs):
            if Path(path).name in cache.RESTORED_INDEX_NAMES: reads.append(str(path))
            return digest(path, **kwargs)
        with mock.patch.object(cache, 'stable_file_digest', side_effect=counted):
            binding = cache.restored_index_binding(root, selection, sha)
            self.assertIs(binding, cache.restored_index_binding(root, selection, sha, previous=binding))
            first = cache.frozen_runtime_context(root, dump, sha, restored_indexes=binding)
            self.assertEqual(first, cache.frozen_runtime_context(root, dump, sha, restored_indexes=binding))
        self.assertEqual([str(root / n) for n in cache.RESTORED_INDEX_NAMES], reads)
        for name in cache.RESTORED_INDEX_NAMES:
            self.assertEqual((root / name).stat().st_ino, (backing / name).stat().st_ino)
            first['runtime_stamps']['assets'][name] = json.loads(original)['runtime_stamps']['assets'][name]
        self.assertEqual(json.loads(original), first)
        self.assertEqual(original, (root / cache.COMPLETED_EXPANDER).read_bytes())
        self.assertEqual(receipt, (root / 'extraction-source.json').read_bytes())
        with self.assertRaises(ValueError): cache.completed_source_binding(root, dump)

    def test_restored_indexes_and_dump_share_original_source(self):
        root, dump, backing, original, selection = self.restored_fixture()
        sha = selection['original_seal_sha256']
        fresh = self.base / 'fresh-dump'; fresh.write_bytes(dump.read_bytes()); dump.unlink()
        descriptor = dict(path=str(fresh), bytes=fresh.stat().st_size, sha256=cache.sha256(fresh))
        with self.assertRaises(ValueError): cache.restored_dump_binding(root, descriptor, sha)
        indexes = cache.restored_index_binding(root, selection, sha)
        restored = cache.restored_dump_binding(root, descriptor, sha, restored_indexes=indexes)
        context = cache.frozen_runtime_context(root, fresh, sha, restored_dump=restored, restored_indexes=indexes)
        self.assertEqual(json.loads(original)['identity'], context['identity'])

    def test_restored_indexes_refuse_unproven_aliases_bytes_and_selection(self):
        for change in ('bytes', 'mode', 'mtime', 'alias-copy', 'alias-symlink', 'source-symlink',
                       'extra-alias', 'name', 'source-receipt', 'manifest', 'manifest-input', 'seal', 'format', 'format-kind'):
            with self.subTest(change=change):
                root, dump, backing, original, selection = self.restored_fixture(malformed='kind' if change == 'format-kind' else change == 'format')
                source = root / 'page-index.tsv'; alias = backing / source.name; old = source.stat()
                if change == 'bytes': source.write_bytes(source.read_bytes().replace(b'fixture', b'changed')); cache.os.utime(source, ns=(old.st_atime_ns, old.st_mtime_ns))
                elif change == 'mode': source.chmod(0o600)
                elif change == 'mtime': cache.os.utime(source, ns=(old.st_atime_ns, old.st_mtime_ns + 1))
                elif change == 'alias-copy': alias.unlink(); alias.write_bytes(source.read_bytes())
                elif change == 'alias-symlink': alias.unlink(); alias.symlink_to(source)
                elif change == 'source-symlink': source.unlink(); source.symlink_to(alias)
                elif change == 'extra-alias': cache.os.link(source, self.base / ('third-' + str(self.sequence)))
                elif change == 'name': selection['names'] = ['dump-streams.tsv']
                elif change == 'source-receipt': (root / 'extraction-source.json').write_bytes(b'{}')
                elif change == 'manifest': (backing / '.complete.json').write_bytes(b'{}')
                elif change == 'manifest-input':
                    p = backing / '.complete.json'; value = json.loads(p.read_bytes()); value['identity']['dump_sha256'] = '0'*64
                    p.write_text(json.dumps(value)); selection['cache_manifest'].update(bytes=p.stat().st_size, sha256=cache.sha256(p))
                elif change == 'seal': (root / cache.COMPLETED_EXPANDER).write_bytes(b'{}')
                expected_error = (self.assertRaisesRegex(ValueError, 'Invalid page title index header') if change == 'format' else
                                  self.assertRaisesRegex(ValueError, 'title/page index kinds differ') if change == 'format-kind' else
                                  self.assertRaises((ValueError, OSError)))
                with expected_error:
                    cache.restored_index_binding(root, selection, selection['original_seal_sha256'])

    def test_restored_index_custody_rejects_late_changes_and_forgery(self):
        for change in ('late-first-alias', 'parent', 'receipt', 'unselected', 'plain-tuple', 'typed-tuple', 'provider'):
            with self.subTest(change=change):
                root, dump, backing, original, selection = self.restored_fixture(); sha = selection['original_seal_sha256']
                binding = cache.restored_index_binding(root, selection, sha)
                if change == 'late-first-alias':
                    p = backing / 'page-index.tsv'; body = p.read_bytes(); p.unlink(); p.write_bytes(body)
                elif change == 'parent': backing.chmod(0o700)
                elif change == 'receipt': (root / 'extraction-source.json').write_bytes(b'{}')
                elif change == 'unselected': (root / 'dict-bundle-expander').chmod(0o600)
                elif change == 'plain-tuple': binding = tuple(binding)
                elif change == 'typed-tuple': binding = cache._RestoredIndexBinding(tuple(binding))
                with self.assertRaises((ValueError, OSError)):
                    cache.frozen_runtime_context(root, dump, sha, restored_indexes=binding, provider_update=change == 'provider')

    def test_final_hash_rechecks_first_alias(self):
        root, dump, backing, original, selection = self.restored_fixture()
        digest = cache.stable_file_digest; fired = []
        def mutating(path, **kwargs):
            result = digest(path, **kwargs)
            if Path(path) == root / 'page-title-index.bin':
                p = backing / 'page-index.tsv'; body = p.read_bytes(); p.unlink(); p.write_bytes(body); fired.append(True)
            return result
        with mock.patch.object(cache, 'stable_file_digest', side_effect=mutating):
            with self.assertRaises(ValueError): cache.restored_index_binding(root, selection, selection['original_seal_sha256'])
        self.assertTrue(fired)




class ObjectCacheSessionTests(unittest.TestCase):
    # Reuse the maintained real object-plan/output fixtures, not a fake cache.
    names = ObjectCacheTest.names
    llvm = ObjectCacheTest.llvm
    complete_missing = ObjectCacheTest.complete_missing
    probe = ObjectCacheTest.probe
    publish = ObjectCacheTest.publish
    seed = ObjectCacheTest.seed
    entry = ObjectCacheTest.entry

    def setUp(self):
        import types
        ObjectCacheTest.setUp(self)
        self.patched.stop()
        self.compiler = self.base / 'compiler'
        self.compiler.write_bytes(b'compiler-v1')
        self.compiler.chmod(0o755)
        self.library = self.base / 'library.so'
        self.library.write_bytes(b'library-v1')
        self.loaded_library = self.library
        self.target, self.version, self.features = 'x86_64-test', 'clang fixture', '+sse2'
        self.probes = []
        def run(argv, **kwargs):
            self.probes.append(argv)
            if argv[0] == 'ldd':
                return types.SimpleNamespace(stdout=f'libfixture => {self.loaded_library} (0x1234)\n')
            if argv[1] == '-dumpmachine': return types.SimpleNamespace(stdout=self.target+'\n')
            if argv[1] == '--version': return types.SimpleNamespace(stdout=self.version+'\n')
            self.assertEqual(argv[1:3], ['-###', '-march=native'])
            return types.SimpleNamespace(stderr=f'"-target-cpu" "test" "-target-feature" "{self.features}"')
        for patcher in (mock.patch.object(cache.shutil, 'which', return_value=str(self.compiler)),
                        mock.patch.object(cache.subprocess, 'run', side_effect=run)):
            patcher.start(); self.addCleanup(patcher.stop)

    def session(self, output, compile_action=None, request_bytes=b'P'):
        import io
        outer = self
        class Request:
            def read(self, count):
                outer.assertEqual(count, 2)
                if compile_action is not None: compile_action()
                return request_bytes
        response = io.BytesIO()
        code = cache.object_cache_session(self.root, 'clang', self.project, output,
                                         self.flags, request=Request(), response=response)
        return code, response.getvalue()

    def trace_tools(self):
        return CompletedExpanderTests._trace_seal_digest_reads(
            self, (self.compiler, self.library))

    def cached_bytes(self):
        return {str(p.relative_to(self.root)): p.read_bytes()
                for p in self.root.rglob('*') if p.is_file()}

    def test_session_preserves_snapshots_cache_bytes_and_all_fresh_tool_probes(self):
        baseline = self.llvm('baseline')
        with self.trace_tools() as old_reads:
            self.assertEqual(cache.MISS, self.probe(baseline))
            self.complete_missing(baseline)
            self.assertEqual(0, self.publish(baseline))
        snapshot = (baseline/'.object-identity.json').read_bytes()
        assets = self.cached_bytes()
        self.root = self.base/'candidate-cache'
        candidate = self.llvm('candidate')
        self.probes.clear()
        with self.trace_tools() as new_reads:
            self.assertEqual((0, b'O3\n'), self.session(candidate, lambda: self.complete_missing(candidate)))
        self.assertEqual(snapshot, (candidate/'.object-identity.json').read_bytes())
        self.assertEqual((baseline/'.object-hits').read_bytes(), (candidate/'.object-hits').read_bytes())
        self.assertEqual(assets, self.cached_bytes())
        self.assertEqual(8, len(self.probes))
        self.assertEqual(2*new_reads['bytes'], old_reads['bytes'])
        self.assertEqual(4, new_reads['opens'])
        # A new transaction has no authority from the previous process-local memo.
        warm = self.llvm('warm')
        with self.trace_tools() as warm_reads:
            self.assertEqual((0, b'O0\n'), self.session(warm, lambda: self.complete_missing(warm)))
        self.assertEqual(new_reads['bytes'], warm_reads['bytes'])
        self.assertEqual('111\n', (warm/'.object-hits').read_text())
        print('OBJECT_SESSION_BYTES '+json.dumps({'baseline':old_reads,'session':new_reads,'new_session':warm_reads},sort_keys=True))

    def test_session_detects_tool_content_replacement_alias_and_observation_changes(self):
        for change in ('restored-mtime', 'replacement', 'symlink', 'compiler', 'target', 'version', 'features', 'libraries'):
            with self.subTest(change=change):
                output = self.llvm('changed-'+change)
                self.root = self.base/('cache-'+change)
                def changed():
                    self.complete_missing(output)
                    before = self.library.stat()
                    if change == 'restored-mtime':
                        self.library.write_bytes(b'library-v2')
                        cache.os.utime(self.library, ns=(before.st_atime_ns,before.st_mtime_ns))
                    elif change in ('replacement','symlink','libraries'):
                        other=self.base/('other-'+change);other.write_bytes(b'library-v3')
                        cache.os.utime(other, ns=(before.st_atime_ns,before.st_mtime_ns))
                        if change=='replacement': other.replace(self.library)
                        elif change=='symlink': self.library.unlink();self.library.symlink_to(other)
                        else: self.loaded_library=other
                    elif change=='compiler': self.compiler.write_bytes(b'compiler-v2')
                    elif change=='target': self.target='changed-target'
                    elif change=='version': self.version='changed-version'
                    else: self.features='-sse2'
                with self.assertRaisesRegex(ValueError,'Clang native target or compile flags changed'):
                    self.session(output,changed)
                self.assertFalse(self.root.exists())
                if self.library.is_symlink(): self.library.unlink()
                self.library.write_bytes(b'library-v1');self.loaded_library=self.library
                self.compiler.write_bytes(b'compiler-v1')
                self.target,self.version,self.features='x86_64-test','clang fixture','+sse2'

    def test_session_retains_plan_metadata_leaf_and_restored_output_checks(self):
        for filename, message in [('batch-plan.tsv','batch-plan.tsv changed'),
                                  ('program.meta','program.meta changed'),
                                  ('value_leaf.bc','value helper bitcode changed')]:
            with self.subTest(filename=filename):
                output=self.llvm('input-'+filename);self.root=self.base/('cache-'+filename)
                def changed():
                    self.complete_missing(output);(output/filename).write_bytes(b'changed')
                with self.assertRaisesRegex(ValueError,message): self.session(output,changed)
                self.assertFalse(self.root.exists())
        self.root=self.base/'restored-cache';self.seed()
        output=self.llvm('restored')
        def changed_restored(): (output/self.names[0]).write_bytes(b'corrupted')
        with self.assertRaisesRegex(ValueError,'Restored native object changed'):
            self.session(output,changed_restored)

    def test_session_abort_extra_request_probe_error_and_changed_snapshot_never_publish(self):
        for request in (b'',b'X',b'PP',b'P\n'):
            with self.subTest(request=request):
                output=self.llvm('abort-'+str(len(list(self.base.iterdir()))))
                with mock.patch.object(cache,'publish_objects') as publish:
                    with self.assertRaisesRegex(ValueError,'not requested exactly once'):
                        self.session(output,request_bytes=request)
                    publish.assert_not_called()
        output=self.llvm('probe-error')
        with mock.patch.object(cache,'probe_objects',side_effect=OSError('read failure')), mock.patch.object(cache,'publish_objects') as publish:
            with self.assertRaisesRegex(OSError,'read failure'): self.session(output)
            publish.assert_not_called()
        output=self.llvm('snapshot')
        def change_snapshot():
            self.complete_missing(output)
            p=output/'.object-identity.json';value=json.loads(p.read_text())
            value['identity']['clang']['tool']['extractor_sha256']='0'*64
            value['_digest_memo']={'pretend':'authenticated'}
            p.write_text(json.dumps(value))
        with self.assertRaisesRegex(ValueError,'Clang native target or compile flags changed'):
            self.session(output,change_snapshot)


if __name__ == "__main__":
    unittest.main()
