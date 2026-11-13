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

    def snapshot_main(self, action, output):
        with mock.patch.object(cache, "tool_identity", return_value=self.expected["tool"]), \
             mock.patch.object(cache, "unicode_case_identity", return_value={"libraries": []}):
            return cache.main(["extraction_cache.py", action, str(self.root),
                               "extractor", "a" * 64, "d" * 64, str(output)])

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
        self.assertEqual(len(prefixes), 3)
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
                    self.assertIsInstance(body[index+1], ast.If)
                    output = self.base / 'outer-output'
                    staging = output / current['edition'] / (current['date'] + '.building')
                    staging.mkdir(parents=True)
                    payload = staging / 'partial-blob';payload.write_bytes(b'unique partial output')
                    namespace = dict(builder.__dict__, output=output, edition=current['edition'], date=current['date'],
                                     retained_roles=SimpleNamespace(sealed_expander_recovery=selected_ref), build_identity=identity)
                    block = ast.fix_missing_locations(ast.Module(body=body[index:index+2], type_ignores=[]))
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


if __name__ == "__main__":
    unittest.main()
