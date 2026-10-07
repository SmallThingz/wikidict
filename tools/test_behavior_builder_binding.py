"""Selected namespace checks against one replayable retained behavior capture."""
import importlib.util
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
sys.path.append(str(Path.cwd()/'tools'))
import build_wiktionaries as build
from test_prepare_behavior_switches import hermetic_capture

class BindingTests(unittest.TestCase):
    def setUp(self):
        temporary=tempfile.TemporaryDirectory();self.addCleanup(temporary.cleanup)
        self.source=hermetic_capture(Path(temporary.name))/'behavior-switches.tsv'
        self.record=json.loads(self.source.with_name('behavior-switches.manifest.json').read_bytes())
    def namespace(self,root):
        for source,target in [('behavior-source-namespace-registry.tsv','namespace-registry.tsv'),('behavior-source-namespace-registry.manifest.json','namespace-registry.manifest.json'),('behavior-source-namespace-siteinfo.raw.json','namespace-siteinfo.raw.json'),('behavior-source-namespace-capture.complete.json','capture.complete.json')]:
            shutil.copyfile(self.source.with_name(source),root/target)
    def test_explicit_selected_namespace_identity(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);self.namespace(root)
            selected={'behavior-switches':self.source,'namespace-registry':root/'namespace-registry.tsv'}
            build.verified_auxiliary_hashes(selected,self.record['wiki'],self.record['date'])
            tsv=root/'namespace-registry.tsv';tsv.write_bytes(tsv.read_bytes()+b'# different registry\n')
            sidecar=root/'namespace-registry.manifest.json';r=json.loads(sidecar.read_bytes());r['output_sha256']=build.sha256_file(tsv);sidecar.write_text(json.dumps(r))
            with self.assertRaisesRegex(ValueError,'different namespace registry'):
                build.verified_auxiliary_hashes(selected,self.record['wiki'],self.record['date'])
    def test_discovered_capture_identity(self):
        for changed in [None,'namespace-registry.tsv','namespace-siteinfo.raw.json','capture.complete.json']:
            with self.subTest(changed=changed),tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp);self.namespace(root)
                if changed:
                    f=root/changed;f.write_bytes(f.read_bytes()+b' ')
                    with self.assertRaisesRegex(ValueError,'different.*namespace'):
                        build.validate_captured_snapshot('behavior-switches',self.source,self.record,[],root)
                else:build.validate_captured_snapshot('behavior-switches',self.source,self.record,[],root)
if __name__=='__main__':unittest.main()
