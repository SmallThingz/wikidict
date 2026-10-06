#!/usr/bin/env python3
"""Capture the pinned French Translate documentation-language name profile.

The generic collector remains byte-identical. This profile admits only the
source-proven qqq hook in the en/fr ALL and single maps. Its API observations
remain current observations, not assertions about the public config deployment.
"""
import importlib.util
import json
from pathlib import Path
import sys

sys.dont_write_bytecode = True
GENERIC_SHA256 = 'e76d9a80f6c5ab32df2ddd596f3b383f2dc604f75eb469fc65ca5006f3a19f03'
DEPENDENCY_PINS = {
    'prepare_language_names_generic.py': GENERIC_SHA256,
    'prepare_file_metadata.py': 'd2a09c741c3fb12ee1a59ea5ce6eeb9611105ffa782d90ca25d3a7b37acf23ab',
    'download_wiktionaries.py': '061472228c81890c4eecc670ea643c8793cb5928cde7854fa4896f5c3c3b29d2',
}
import prepare_file_metadata as evidence

_generic_path = Path(evidence.__file__).with_name('prepare_language_names_generic.py')
if evidence.digest(evidence.small(_generic_path)) != GENERIC_SHA256:
    raise ValueError('Unreviewed generic language-name collector')
_spec = importlib.util.spec_from_file_location('_wikidict_translate_names_private', _generic_path)
_base = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_base)
_original_primary = _base.primary_contract
_original_finish = _base.finish_profile
_original_reconstruct = _base.reconstruct
_original_capture = _base.capture

SCHEMA = 'wikidict.language-names-translate-capture.v1'
KIND, PREFIX, COMPLETE = _base.KIND, _base.PREFIX, _base.COMPLETE
MAX_MANIFEST, MAX_RESPONSE = _base.MAX_MANIFEST, _base.MAX_RESPONSE
MAX_REQUESTS = 16
CORE = '79b81ba96674efc8a803fc956bc501d347d440d2'
DOCUMENTATION_NAMES = {'en': 'Message documentation', 'fr': 'Documentation du message'}
TRANSLATE_SOURCE_PINS = {
    'translate-extension.json': '7eaff1013f79d3bb64f125a5b622145e617f1f39b71106171cfd6be021a6f5e2',
    'translate-HookHandler.php': '5e95da686e77bb33075c6c14930986d75023c8c2b2958c79ead9fc731fa73a58',
    'translate-en.json': 'acaba6fc83f9fb7b513b3d694a2ed3ab72f225fab39afcf8caa8ddd85713d4f6',
    'translate-fr.json': 'f2882b79815f8afe7447de2685f7899512dda7cfd7692783af13b10d23488cb3',
    'wmf-translate.dblist': '0a3dc3b3f695fe9fa9e6038e026150f20b57cbfe260087141253f0bec76a799e',
    'wmf-translate-config-catalog.json': '8f632ab532524ffc83b2e22ed5b1f8647cbaa2b30f83b2211d50d83833b85955',
    'wmf-translate-config-tree.json': 'f82c56aaf86e39f2ccbd70749f834634d084f0179694bff584bea44c88d5e46a',
}


def producer():
    dependencies = {}
    for name, expected in DEPENDENCY_PINS.items():
        actual = evidence.digest(evidence.small(Path(evidence.__file__).with_name(name)))
        if actual != expected:
            raise ValueError('Translate profile dependency changed: ' + name)
        dependencies[name] = actual
    return {'generator_sha256': evidence.digest(evidence.small(Path(__file__))),
            'dependency_sha256': dependencies}


def primary_contract(root, prefix=''):
    sources, aliases, tables = _original_primary(root, prefix)
    for name, expected in TRANSLATE_SOURCE_PINS.items():
        raw = evidence.small(Path(root) / (prefix + name), _base.MAX_SOURCE)
        if evidence.digest(raw) != expected:
            raise ValueError('Unreviewed Translate primary source: ' + name)
        sources[name] = raw
    extension = evidence.decode(sources['translate-extension.json'])
    if extension['Hooks']['LanguageGetTranslatedLanguageNames'] != (
            'MediaWiki\\Extension\\Translate\\HookHandler::translateMessageDocumentationLanguage'):
        raise ValueError('Translate hook registration differs')
    for language, expected in DOCUMENTATION_NAMES.items():
        if evidence.decode(sources['translate-' + language + '.json'])[
                'translate-documentation-language'] != expected:
            raise ValueError('Translate documentation-name source differs')
    if 'frwiktionary' not in sources['wmf-translate.dblist'].decode('utf-8').splitlines():
        raise ValueError('French Wiktionary is not in the pinned Translate group')
    catalog = evidence.decode(sources['wmf-translate-config-catalog.json'])
    tree = evidence.decode(sources['wmf-translate-config-tree.json'])
    commit = 'cb5a4a08978a7c8a180837d8236afe616c619bf8'
    if catalog['commit'] != commit or tree['sha'] != commit or tree['truncated'] is not False:
        raise ValueError('Incomplete or mismatched Translate config provenance')
    return sources, aliases, tables


def finish_profile(single, mw, aliases, tables, display, fallbacks):
    if display not in DOCUMENTATION_NAMES or single.get('qqq') != DOCUMENTATION_NAMES[display]:
        raise ValueError('Missing or changed observed Translate documentation name')
    if 'qqq' in mw or 'qqq' in aliases:
        raise ValueError('Translate qqq must remain outside MW-defined names and aliases')
    ordinary = dict(single)
    del ordinary['qqq']
    result = _original_finish(ordinary, mw, aliases, tables, display, fallbacks)
    if 'qqq' in result['all'] or 'qqq' in result['single']:
        raise ValueError('Translate hook conflicts with the ordinary name profile')
    # The pinned hook contributes to translated names before the core ALL/DEFINED
    # split; the authoritative API confirms the resulting value for both scopes.
    result['all']['qqq'] = single['qqq']
    result['single']['qqq'] = single['qqq']
    return result


def reconstruct(config, batches, aliases, tables):
    if (config.get('wiki') != 'frwiktionary' or config.get('content_language') != 'fr'
            or config.get('languages') != ['en', 'fr'] or config.get('core') != CORE
            or 'extra_direction_codes' in config or 'direction_profile' in config):
        raise ValueError('Unsupported Translate language-name profile')
    return _original_reconstruct(config, batches, aliases, tables)


def capture(args, transport=None, sleep=_base.time.sleep):
    languages = sorted(set(args.languages or ['en', 'fr']))
    if (args.wiki != 'frwiktionary' or languages != ['en', 'fr']
            or getattr(args, 'core', None) != CORE
            or getattr(args, 'extra_direction_codes', [])):
        raise ValueError('Unsupported Translate capture scope')
    namespace = evidence.small(args.namespace_registry)
    if _base.namespace_identity(namespace, args.wiki, args.date) != 'fr':
        raise ValueError('Translate capture needs the pinned French namespace')
    return _original_capture(args, transport, sleep)


# These assignments affect only the private module instance, never an imported
# generic collector used by the builder or another capture in this process.
_base.SCHEMA = SCHEMA
_base.MAX_REQUESTS = MAX_REQUESTS
_base.producer = producer
_base.primary_contract = primary_contract
_base.finish_profile = finish_profile
_base.reconstruct = reconstruct
_base.capture = capture
verify = _base.verify
validate_snapshot = _base.validate_snapshot
capture_artifacts = _base.capture_artifacts
main = _base.main

if __name__ == '__main__':
    main()
