#!/usr/bin/env python3
"""Capture v2 site-info with seven current Scribunto counters from one response.

The existing namespace capture is immutable. This profile creates a separate
generation and preserves the complete API response, including failed retries.
The historical installed filename namespace-siteinfo.raw.json now carries an
explicit v2 envelope; the original HTTP bytes have their own receipt-bound file.
"""
import argparse
from datetime import datetime
import json
from pathlib import Path
import re
import sys
import time
import urllib.parse

sys.dont_write_bytecode = True
import prepare_file_metadata as evidence
import site_info_snapshot as legacy

SCHEMA = 'wikidict.site-info-capture.v2'
HEADER = 'wikidict.site-info.v2'
PROFILE = 'general-and-seven-scribunto-statistics'
FIGURE_PROFILE = 'general-statistics-and-figure-default-options'
SNAPSHOT = 'namespace-siteinfo.raw.json'
MANIFEST = 'site-info.manifest.json'
COMPLETE = 'site-info.complete.json'
PREFIX = 'site-info.'
CORE = '0d3b507d19ae860ed8a1d22c73fa4bc5abf8dfcc'
# Exact deployment revisions whose complete ApiQuerySiteinfo.php is byte-identical
# to SOURCE_PINS below; other revisions require another explicit source review.
CORE_PROFILES = (CORE, '79b81ba96674efc8a803fc956bc501d347d440d2',
                 '0470f6c99a6456a366635bf25a517a1f951de6f5',
                 'ead780177c5a02aa63ac6fd3a50977df9719fe63',
                 'f45897451256aa3799aecc5d7ee320ade22beaec',
                 '992ad5e3679f848254828e823860ba8b3ad3b39b',
                 'bfe24921d500b20f2938fb8fe2a09cf5cac80161',
                 '6e76237de1cf29c08427d191f110a2c38c2b4cf9',
                 'd1919ec5e4ebd7b0dea1ff6ea1cb4347a9349ca2')
SCRIBUNTO = 'b109cb6e5866c13871e308859ef78249b1bd3ea2'
FIGURE_WMF5_CORE = '87f311882d8c84ec21e288d0bde8aa289df8dc56'
FIGURE_WMF5_SCRIBUNTO = '25f7cdefa45a3b8417d7fa296f86b76537927f43'
# Retained CSB response: current Figure defaults only, never main site-info.
# This core changes only DatabaseMySQL.php from the reviewed EN core;
# the complete ApiQuerySiteinfo source remains SOURCE_PINS-identical.
FIGURE_CSB_CORE = '7fb9c913ca612a2e6176762b3eb4d0301166e88e'
FIGURE_CSB_DEFAULTS = ('20261001', '862b5a0e908b6fba2236583698a9606c53f692090c0aff1ccbe47a87e26269b7')
FIGURE_MON_CORE = '57f2a6bfacc3c5cecc269214a8d726b0b6faa596'
FIGURE_MON_DEFAULTS = ('20261001', 'da834f0e0f84cc57b24bfc1ca633fb0969f8c046cd99d8837fbcb91dcf53394a')
SEPTEMBER_EN_CORE = 'db332802a5f05525b779baadbf8d3394bc7d989e'
# The deployed English core and Scribunto leaves match SOURCE_PINS. Bind only
# the two retained HTTP observations reviewed against the September namespace.
SEPTEMBER_EN_OBSERVATIONS = {
    PROFILE: ('20260901', '83fcd31286d6be77e11d199c5e1615078a1b4c0b2bf3b08b11508c55e103f976'),
    FIGURE_PROFILE: ('20260901', 'bdfe398945abd372cdb7d12df74c586c4843f1711786949bc1478889967693d5'),
}
FIGURE_CURRENT_DEFAULTS = {
    'mnwwiktionary': FIGURE_MON_DEFAULTS,
    'sawiktionary': ('20261001', '6a84129b4f0ccfb7f4909e3b3e19303718715fe204b3ead69172379e1513d4ec'),
    'shwiktionary': ('20261001', '7d2c6464848edc6a27d77d9267d96d5b263ef4cc6429b9444d7fa49bc8894d2d'),
}
FIGURE_WMF5_SR_RAW = '9755bd766754d1d6e0ede764ca11eb351c4da75363cb6297c70668dba657b31f'
FIGURE_WMF5_DEFAULTS = {
    'thwiktionary': ('20261001', '424f330eb29ae006d684238cf2d8dedc254af22f49d4a01e2224224212e85ac2'),
    'itwiktionary': ('20261001', 'd99f3db235d0de81adc47a2951306c4d534c38d7e97bb67ebfa4dfe4ab560b93'),
    'dewiktionary': ('20261001', 'fcec36637c8e8422b07a70996c64f9f9a12eba3259c902e737d304a834319357'),
    'ruwiktionary': ('20261001', '271ab18b8e25afe3e1c5e7fcda9514c6b5f5bfbcc04bc38c93434201db514b50'),
    'srwiktionary': ('20261001', FIGURE_WMF5_SR_RAW),
    'viwiktionary': ('20261001', '36f91d60b106a4cd26045775717de845d267faa5e76b4a801682db2dcd497ad4'),
}
MAX_RESPONSE = 2 * 1024 * 1024
MAX_MANIFEST = 64 * 1024
MAX_INTEGER = 2**53 - 1
PRODUCER_DEPENDENCIES = ('prepare_file_metadata.py', 'download_wiktionaries.py',
                         'site_info_snapshot.py', 'namespace_registry_snapshot.py')
FIELDS = {'pages': 'pages', 'articles': 'articles', 'files': 'images',
          'edits': 'edits', 'users': 'users', 'activeUsers': 'activeusers', 'admins': 'admins'}
SOURCE_PINS = {
    'ApiQuerySiteinfo.php': 'a318da6f2cae4275a15595a93aa324bcbeb433381b29bd356fc577f72d5c2ced',
    'SiteLibrary.php': '564db2fbec6c5e9bb46e02eccf1d1b9cde9fac7f5e02efaccf185b2f7c69e60d',
    'mw.site.lua': '97555f7f9c575fd098f78a72ad590ef753b7389c5715d521168635c63dabbab8',
}


def stamp(value):
    if not isinstance(value, str):
        raise ValueError('Missing observation timestamp')
    result = datetime.fromisoformat(value.replace('Z', '+00:00'))
    if result.tzinfo is None:
        raise ValueError('Observation timestamp lacks timezone')
    return result


def namespace_identity(raw, wiki, date):
    evidence.wiktionary_api(wiki)
    if not isinstance(date, str) or not re.fullmatch('[0-9]{8}', date):
        raise ValueError('Invalid dump date')
    datetime.strptime(date, '%Y%m%d')
    lines = raw.decode().splitlines()
    if len(lines) < 4 or lines[:3] != ['# wikidict-namespace-registry-v1',
            '# wiki\t' + wiki, '# dump-date\t' + date] or not lines[3].startswith('# content-language\t'):
        raise ValueError('Namespace edition/date mismatch')
    language = lines[3].split('\t', 1)[1]
    if not re.fullmatch('[a-z0-9-]{2,128}', language):
        raise ValueError('Invalid namespace content language')
    return language


def producer():
    return {'generator_sha256': evidence.digest(evidence.small(Path(__file__))),
            'dependency_sha256': {name: evidence.digest(evidence.small(Path(evidence.__file__).with_name(name)))
                for name in PRODUCER_DEPENDENCIES}}



def validate_producer_provenance(manifest):
    # Retain the original producer identity as provenance, not executable trust.
    # verify() always replays the complete capture using the current verifier.
    generator = manifest.get('generator_sha256')
    dependencies = manifest.get('dependency_sha256')
    if (not isinstance(generator, str) or re.fullmatch('[0-9a-f]{64}', generator) is None
            or not isinstance(dependencies, dict) or set(dependencies) != set(PRODUCER_DEPENDENCIES)
            or any(not isinstance(value, str) or re.fullmatch('[0-9a-f]{64}', value) is None
                   for value in dependencies.values())):
        raise ValueError('Invalid recorded site-info producer provenance')


def primary_sources(root, prefix=''):
    result = {}
    for name, expected in SOURCE_PINS.items():
        raw = evidence.small(Path(root) / (prefix + name), MAX_RESPONSE)
        if evidence.digest(raw) != expected:
            raise ValueError('Unreviewed primary source: ' + name)
        result[name] = raw
    return result


def query(profile=PROFILE):
    if profile not in (PROFILE, FIGURE_PROFILE):
        raise ValueError('Unreviewed site-info query profile')
    return {'action': 'query', 'meta': 'siteinfo',
            'siprop': 'general|statistics|defaultoptions' if profile == FIGURE_PROFILE else 'general|statistics',
            'format': 'json', 'formatversion': '2', 'maxlag': '5'}


def figure_thumbnail_width(result):
    # ApiQuerySiteinfo compacts ThumbLimits and remaps the configured default
    # index in the same response. Do not interpret it as the original PHP key.
    general = result.get('general')
    limits = general.get('thumblimits') if isinstance(general, dict) else None
    if isinstance(limits, dict):
        if set(limits) != {str(index) for index in range(len(limits))}:
            raise ValueError('Noncompact figure thumbnail limits')
        limits = [limits[str(index)] for index in range(len(limits))]
    options = result.get('defaultoptions')
    index = options.get('thumbsize') if isinstance(options, dict) else None
    if (not isinstance(limits, list) or not limits
            or any(type(width) is not int or not 1 <= width <= 2**32-1 for width in limits)
            or type(index) is not int or not 0 <= index < len(limits)):
        raise ValueError('Missing or invalid same-response figure thumbnail default')
    return limits[index]


def response(data, wiki, language, profile=PROFILE, *, raw_sha=None, date=None):
    if not isinstance(data, dict) or any(key in data for key in ('error', 'errors', 'warnings', 'continue')):
        raise ValueError('Unsuccessful or incomplete site-info API response')
    result = data.get('query')
    general = result.get('general') if isinstance(result, dict) else None
    if (not isinstance(general, dict) or general.get('wikiid') != wiki
            or general.get('lang') != language or not reviewed_source(general.get('git-hash'), profile, wiki)):
        raise ValueError('Site-info edition/language/source mismatch')
    core = general.get('git-hash')
    if core == SEPTEMBER_EN_CORE and (date, raw_sha) != SEPTEMBER_EN_OBSERVATIONS[profile]:
        raise ValueError('Unreviewed September English site-info observation')
    binding = file_defaults_observation(core, wiki)
    if binding is not None:
        reviewed_date, reviewed_sha = binding
        if (raw_sha != reviewed_sha or (date is not None and date != reviewed_date)
                or (core == FIGURE_CSB_CORE and date is None)):
            raise ValueError('Unreviewed Figure default-options observation')
    legacy.validate_server(general.get('server'))
    stamp(general.get('time'))
    counters = result.get('statistics')
    if not isinstance(counters, dict) or any(type(counters.get(key)) is not int
            or not 0 <= counters[key] <= MAX_INTEGER for key in FIELDS.values()):
        raise ValueError('Missing or invalid complete site statistics')
    query(profile)
    if profile == FIGURE_PROFILE:
        figure_thumbnail_width(result)
    return result


def file_defaults_observation(core, wiki):
    if core == FIGURE_CSB_CORE and wiki == 'csbwiktionary':
        return FIGURE_CSB_DEFAULTS
    if core == FIGURE_WMF5_CORE and isinstance(wiki, str):
        return FIGURE_WMF5_DEFAULTS.get(wiki)
    if core == FIGURE_MON_CORE and isinstance(wiki, str):
        return FIGURE_CURRENT_DEFAULTS.get(wiki)
    return None


def reviewed_source(core, profile, wiki):
    return (core in CORE_PROFILES
            or (core == SEPTEMBER_EN_CORE and wiki == 'enwiktionary' and profile in SEPTEMBER_EN_OBSERVATIONS)
            or (profile == FIGURE_PROFILE and file_defaults_observation(core, wiki) is not None))


def scribunto_reference(core):
    # These observed core revisions select Scribunto with the same pinned library leaves.
    return FIGURE_WMF5_SCRIBUNTO if core in (FIGURE_WMF5_CORE, FIGURE_MON_CORE, SEPTEMBER_EN_CORE, FIGURE_CSB_CORE) else SCRIBUNTO


def render(data, config, retrieved, raw_sha):
    result = response(data, config['wiki'], config['content_language'], config['profile'], raw_sha=raw_sha, date=config['date'])
    return evidence.encoded({'schema': HEADER, **config, 'temporal_scope': 'current-api-observation',
        'retrieved_utc': retrieved, 'raw_response_sha256': raw_sha, 'query': result})


def payload(root, *, embedded=False):
    rows = {}
    for path in root.iterdir():
        if path.name in (MANIFEST, COMPLETE):
            continue
        if path.name != SNAPSHOT and not path.name.startswith(PREFIX):
            # An outer Figure capture verifies its own complete inventory. Its
            # site-info component still has this exact independently replayed
            # manifest, HTTP history and original projection.
            if embedded:
                continue
            raise ValueError('Unexpected capture artifact: ' + path.name)
        raw = evidence.small(path, MAX_RESPONSE)
        rows[path.name] = {'size': len(raw), 'sha256': evidence.digest(raw)}
    return dict(sorted(rows.items()))


def capture(args, transport=None, sleep=time.sleep):
    if not 0 <= args.delay <= 60 or not 1 <= args.wall_seconds <= 3600:
        raise ValueError('Invalid capture bounds')
    namespace = evidence.small(args.namespace_registry, MAX_RESPONSE)
    language = namespace_identity(namespace, args.wiki, args.date)
    sources = primary_sources(args.primary_sources, getattr(args, 'primary_sources_prefix', ''))
    profile = FIGURE_PROFILE if getattr(args, 'figure_defaults', False) else PROFILE
    config = {'wiki': args.wiki, 'date': args.date, 'content_language': language,
              'namespace_registry_sha256': evidence.digest(namespace), 'profile': profile}
    identity = producer()
    root = Path(args.output)
    root.mkdir(parents=True, exist_ok=False)
    started, deadline = evidence.utc(), time.monotonic() + args.wall_seconds
    try:
        evidence.put(root / (PREFIX + 'namespace-registry.tsv'), namespace)
        for name, raw in sources.items():
            evidence.put(root / (PREFIX + 'source-' + name), raw)
        url = evidence.wiktionary_api(args.wiki) + '?' + urllib.parse.urlencode(sorted(query(profile).items()))
        request = {'url': url, 'query': query(profile), **config}
        evidence.document(root / (PREFIX + 'request.json'), request)
        accepted = None
        for attempt in range(1, 5):
            if time.monotonic() >= deadline:
                raise ValueError('Capture deadline reached')
            name = PREFIX + f'{attempt:02d}'
            receipt = {'request': PREFIX + 'request.json', 'started_utc': evidence.utc()}
            retry, headers = False, {}
            try:
                status, headers, raw = (transport or evidence.get_response)(url, min(30, deadline - time.monotonic()))
                receipt.update(status=status, response=name + '.raw.json', response_bytes=len(raw),
                    response_sha256=evidence.digest(raw), headers={k.lower(): v for k, v in headers.items()
                    if k.lower() in ('date', 'content-type', 'retry-after', 'etag')})
                evidence.put(root / receipt['response'], raw)
                if len(raw) > MAX_RESPONSE:
                    raise ValueError('Oversized API response')
                if status != 200:
                    retry = status in (429, 500, 502, 503, 504)
                    raise ValueError('HTTP status ' + str(status))
                data = evidence.decode(raw)
                if isinstance(data, dict) and isinstance(data.get('error'), dict):
                    retry = data['error'].get('code') in ('maxlag', 'ratelimited', 'readonly')
                response(data, args.wiki, language, profile, raw_sha=receipt['response_sha256'], date=args.date)
                receipt.update(accepted=True, ended_utc=evidence.utc())
                evidence.document(root / (name + '.receipt.json'), receipt)
                accepted = name + '.receipt.json'
                break
            except (ValueError, OSError) as error:
                receipt.update(accepted=False, ended_utc=evidence.utc(), error=str(error))
                evidence.document(root / (name + '.receipt.json'), receipt)
                if not (retry or isinstance(error, OSError)) or attempt == 4:
                    raise
                retry_after = next((str(v) for k, v in headers.items() if k.lower() == 'retry-after'), '')
                if retry_after and not retry_after.isdigit():
                    raise ValueError('Unsupported Retry-After') from error
                wait = max(args.delay, 2**(attempt-1), int(retry_after or 0))
                if wait > 60 or time.monotonic() + wait >= deadline:
                    raise ValueError('Retry exceeds bounded deadline') from error
                sleep(wait)
        output = render(data, config, receipt['ended_utc'], evidence.digest(raw))
        if producer() != identity or evidence.small(args.namespace_registry, MAX_RESPONSE) != namespace:
            raise ValueError('Capture producer or namespace changed')
        evidence.put(root / SNAPSHOT, output)
        core = data['query']['general']['git-hash']
        manifest = {'schema': SCHEMA, **config, **identity, 'core': core, 'scribunto': scribunto_reference(core),
            'temporal_scope': 'current-api-observation', 'dump_date': None,
            'started_utc': started, 'retrieved_utc': receipt['ended_utc'], 'accepted_receipt': accepted,
            'source_url': url, 'output_sha256': evidence.digest(output), 'output_bytes': len(output),
            'artifacts': payload(root)}
        evidence.document(root / MANIFEST, manifest)
        verify(root, require_complete=False)
        evidence.document(root / COMPLETE, {'schema': SCHEMA, 'manifest_sha256': evidence.digest(evidence.small(root / MANIFEST, MAX_MANIFEST))})
        return manifest
    except BaseException as error:
        for name in (SNAPSHOT, MANIFEST, COMPLETE):
            path = root / name
            if path.exists():
                path.rename(root / (name + '.unverified'))
        evidence.document(root / (PREFIX + 'failure.json'), {'ended_utc': evidence.utc(), 'error': str(error)})
        raise


def revalidate(root, failure_sha256):
    """Qualify one retained HTTP 200 after a source-profile review, without HTTP.

    The failed receipt and failure record remain immutable. Acceptance belongs to
    this verifier and is explicit in the new manifest, not the original receipt.
    """
    root = Path(root)
    if root.is_symlink() or not root.is_dir():
        raise ValueError('Unsafe capture directory')
    expected_files = {PREFIX+'request.json', PREFIX+'namespace-registry.tsv',
                      *(PREFIX+'source-'+name for name in SOURCE_PINS),
                      PREFIX+'01.raw.json', PREFIX+'01.receipt.json', PREFIX+'failure.json'}
    if {p.name for p in root.iterdir()} != expected_files:
        raise ValueError('Revalidation requires an untouched first-attempt source refusal')
    before = payload(root)
    failure_raw = evidence.small(root/(PREFIX+'failure.json'), MAX_MANIFEST)
    if evidence.digest(failure_raw) != failure_sha256:
        raise ValueError('Retained failure identity mismatch')
    receipt_raw = evidence.small(root/(PREFIX+'01.receipt.json'), MAX_MANIFEST)
    receipt = evidence.decode(receipt_raw)
    failure = evidence.decode(failure_raw)
    if (receipt.get('accepted') is not False or receipt.get('status') != 200
            or receipt.get('error') != 'Site-info edition/language/source mismatch'
            or failure.get('error') != receipt['error']):
        raise ValueError('Only a retained HTTP 200 source-profile refusal may be revalidated')
    request = evidence.decode(evidence.small(root/(PREFIX+'request.json'), MAX_MANIFEST))
    config = {key: request[key] for key in ('wiki', 'date', 'content_language', 'namespace_registry_sha256', 'profile')}
    namespace = evidence.small(root/(PREFIX+'namespace-registry.tsv'), MAX_RESPONSE)
    if (namespace_identity(namespace, config['wiki'], config['date']) != config['content_language']
            or evidence.digest(namespace) != config['namespace_registry_sha256']):
        raise ValueError('Revalidation namespace binding mismatch')
    primary_sources(root, PREFIX+'source-')
    url = evidence.wiktionary_api(config['wiki'])+'?'+urllib.parse.urlencode(sorted(query(config['profile']).items()))
    if request != {'url': url, 'query': query(config['profile']), **config}:
        raise ValueError('Unrequested site-info query')
    if receipt.get('request') != PREFIX+'request.json' or receipt.get('response') != PREFIX+'01.raw.json':
        raise ValueError('Revalidation receipt path mismatch')
    raw = evidence.small(root/receipt['response'], MAX_RESPONSE)
    if receipt.get('response_bytes') != len(raw) or receipt.get('response_sha256') != evidence.digest(raw):
        raise ValueError('Response receipt hash mismatch')
    if not stamp(receipt['started_utc']) <= stamp(receipt['ended_utc']) <= stamp(failure['ended_utc']):
        raise ValueError('Invalid retained refusal chronology')
    data = evidence.decode(raw)
    output = render(data, config, receipt['ended_utc'], evidence.digest(raw))
    reviewed = evidence.utc()
    if stamp(reviewed) < stamp(failure['ended_utc']):
        raise ValueError('Revalidation predates retained refusal')
    identity = producer()
    core = data['query']['general']['git-hash']
    manifest = {'schema': SCHEMA, **config, **identity, 'core': core, 'scribunto': scribunto_reference(core),
        'temporal_scope': 'current-api-observation', 'dump_date': None,
        'started_utc': receipt['started_utc'], 'retrieved_utc': receipt['ended_utc'],
        'accepted_receipt': PREFIX+'01.receipt.json',
        'revalidation': {'kind': 'retained-source-profile-refusal', 'reviewed_utc': reviewed,
            'receipt_sha256': evidence.digest(receipt_raw), 'failure_sha256': failure_sha256},
        'source_url': url, 'output_sha256': evidence.digest(output), 'output_bytes': len(output)}
    if payload(root) != before or producer() != identity:
        raise ValueError('Retained capture or revalidation producer changed')
    evidence.put(root/SNAPSHOT, output)
    manifest['artifacts'] = payload(root)
    evidence.document(root/MANIFEST, manifest)
    verify(root, require_complete=False)
    evidence.document(root/COMPLETE, {'schema': SCHEMA,
        'manifest_sha256': evidence.digest(evidence.small(root/MANIFEST, MAX_MANIFEST))})
    return manifest


def verify(root, require_complete=True, *, embedded=False):
    root = Path(root)
    if root.is_symlink() or not root.is_dir():
        raise ValueError('Unsafe capture directory')
    raw_manifest = evidence.small(root / MANIFEST, MAX_MANIFEST)
    manifest = evidence.decode(raw_manifest)
    if (not isinstance(manifest, dict) or manifest.get('schema') != SCHEMA or manifest.get('profile') not in (PROFILE, FIGURE_PROFILE)
            or not reviewed_source(manifest.get('core'), manifest.get('profile'), manifest.get('wiki'))
            or manifest.get('scribunto') != scribunto_reference(manifest.get('core'))
            or manifest.get('temporal_scope') != 'current-api-observation' or manifest.get('dump_date') is not None):
        raise ValueError('Unreviewed site-info capture profile or producer')
    validate_producer_provenance(manifest)
    if require_complete and evidence.decode(evidence.small(root / COMPLETE, MAX_MANIFEST)) != {
            'schema': SCHEMA, 'manifest_sha256': evidence.digest(raw_manifest)}:
        raise ValueError('Capture completion mismatch')
    if manifest.get('artifacts') != payload(root, embedded=embedded):
        raise ValueError('Capture evidence inventory mismatch')
    primary_sources(root, PREFIX + 'source-')
    namespace = evidence.small(root / (PREFIX + 'namespace-registry.tsv'), MAX_RESPONSE)
    language = namespace_identity(namespace, manifest['wiki'], manifest['date'])
    config = {k: manifest[k] for k in ('wiki', 'date', 'content_language', 'namespace_registry_sha256', 'profile')}
    if language != config['content_language'] or evidence.digest(namespace) != config['namespace_registry_sha256']:
        raise ValueError('Capture namespace binding mismatch')
    request = evidence.decode(evidence.small(root / (PREFIX + 'request.json'), MAX_MANIFEST))
    url = evidence.wiktionary_api(config['wiki']) + '?' + urllib.parse.urlencode(sorted(query(config['profile']).items()))
    if request != {'url': url, 'query': query(config['profile']), **config} or manifest.get('source_url') != url:
        raise ValueError('Unrequested site-info query')
    accepted = manifest.get('accepted_receipt')
    if not isinstance(accepted, str) or not re.fullmatch(r'site-info\.0[1-4]\.receipt\.json', accepted):
        raise ValueError('Invalid accepted receipt')
    number = int(accepted.split('.')[1])
    revalidation = manifest.get('revalidation')
    if revalidation is not None:
        if (not isinstance(revalidation, dict) or set(revalidation) != {
                'kind', 'reviewed_utc', 'receipt_sha256', 'failure_sha256'}
                or revalidation.get('kind') != 'retained-source-profile-refusal' or number != 1):
            raise ValueError('Invalid retained-response revalidation')
        failure_raw = evidence.small(root/(PREFIX+'failure.json'), MAX_MANIFEST)
        failure = evidence.decode(failure_raw)
        original_receipt = evidence.small(root/accepted, MAX_MANIFEST)
        if (evidence.digest(failure_raw) != revalidation['failure_sha256']
                or evidence.digest(original_receipt) != revalidation['receipt_sha256']
                or failure.get('error') != 'Site-info edition/language/source mismatch'
                or not stamp(manifest['retrieved_utc']) <= stamp(failure['ended_utc']) <= stamp(revalidation['reviewed_utc'])):
            raise ValueError('Revalidation differs from original refusal')
    expected_files = {SNAPSHOT, PREFIX+'request.json', PREFIX+'namespace-registry.tsv',
                      *(PREFIX+'source-'+name for name in SOURCE_PINS)}
    if revalidation is not None:
        expected_files.add(PREFIX+'failure.json')
    previous = stamp(manifest['started_utc'])
    for attempt in range(1, number+1):
        name = PREFIX + f'{attempt:02d}'
        receipt_name = name + '.receipt.json'
        expected_files.add(receipt_name)
        receipt = evidence.decode(evidence.small(root / receipt_name, MAX_MANIFEST))
        start, end = stamp(receipt.get('started_utc')), stamp(receipt.get('ended_utc'))
        expected_acceptance = attempt == number and revalidation is None
        if (revalidation is not None and (receipt.get('error') != 'Site-info edition/language/source mismatch'
                or receipt.get('status') != 200)):
            raise ValueError('Revalidation lacks original HTTP 200 source refusal')
        if start < previous or end < start or receipt.get('request') != PREFIX+'request.json' or receipt.get('accepted') is not expected_acceptance:
            raise ValueError('Invalid receipt order or acceptance')
        previous = end
        if 'response' in receipt:
            if receipt['response'] != name+'.raw.json':
                raise ValueError('Unsafe or mismatched response path')
            expected_files.add(receipt['response'])
            raw = evidence.small(root / receipt['response'], MAX_RESPONSE)
            if receipt.get('response_bytes') != len(raw) or receipt.get('response_sha256') != evidence.digest(raw):
                raise ValueError('Response receipt hash mismatch')
        elif attempt == number:
            raise ValueError('Accepted response absent')
        if attempt == number:
            if receipt.get('status') != 200 or receipt['ended_utc'] != manifest['retrieved_utc']:
                raise ValueError('Accepted HTTP or observation mismatch')
            observed = evidence.decode(raw)
            expected = render(observed, config, receipt['ended_utc'], evidence.digest(raw))
            if manifest['core'] != observed['query']['general']['git-hash']:
                raise ValueError('Site-info manifest core differs from API observation')
    if set(manifest['artifacts']) != expected_files:
        raise ValueError('Unexpected or incomplete retry inventory')
    if (evidence.small(root / SNAPSHOT, MAX_RESPONSE) != expected or manifest.get('output_bytes') != len(expected)
            or manifest.get('output_sha256') != evidence.digest(expected)):
        raise ValueError('Site-info projection differs from complete API response')
    return manifest


def validate_snapshot(path, wiki=None, date=None, *, file_defaults=False):
    path = Path(path)
    if path.name != SNAPSHOT:
        raise ValueError('Unexpected site-info snapshot filename')
    manifest = verify(path.parent)
    defaults_only = (file_defaults_observation(manifest['core'], manifest['wiki']) is not None
                     or (manifest['core'] == SEPTEMBER_EN_CORE and manifest['profile'] == FIGURE_PROFILE))
    if defaults_only and not file_defaults:
        raise ValueError('This default-options observation is scoped to the ImageInfo source binding')
    if (wiki is not None and manifest['wiki'] != wiki) or (date is not None and manifest['date'] != date):
        raise ValueError('Site-info edition/date mismatch')
    return manifest


def capture_artifacts(path, manifest=None, *, file_defaults=False):
    validated = validate_snapshot(path, file_defaults=file_defaults)
    if manifest is not None and validated != manifest:
        raise ValueError('Capture changed during pinning')
    return {**{name: row['sha256'] for name, row in validated['artifacts'].items()},
            **{name: evidence.digest(evidence.small(Path(path).with_name(name), MAX_MANIFEST))
               for name in (MANIFEST, COMPLETE)}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    check = sub.add_parser('verify'); check.add_argument('output', type=Path)
    recover = sub.add_parser('revalidate', help='Qualify a retained HTTP 200 after source review without another request')
    recover.add_argument('output', type=Path)
    recover.add_argument('--failure-sha256', required=True)
    collect = sub.add_parser('capture')
    for name in ('wiki', 'date'):
        collect.add_argument('--'+name, required=True)
    for name in ('namespace-registry', 'primary-sources', 'output'):
        collect.add_argument('--'+name, type=Path, required=True)
    collect.add_argument('--delay', type=float, default=1)
    collect.add_argument('--wall-seconds', type=int, default=180)
    collect.add_argument('--figure-defaults', action='store_true',
                         help='Capture thumbnail defaults together with general info and statistics')
    args = parser.parse_args()
    if args.command == 'capture' and args.delay < 1:
        parser.error('Network retries require at least one second of spacing')
    result = (capture(args) if args.command == 'capture' else
              revalidate(args.output, args.failure_sha256) if args.command == 'revalidate' else verify(args.output))
    print(json.dumps({key: result[key] for key in ('wiki','date','output_sha256','retrieved_utc')}))


if __name__ == '__main__':
    main()
