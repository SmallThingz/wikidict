#!/usr/bin/env python3
"""Replay and stage source-backed Figure inputs without network acquisition.

A finite occurrence capture never implies whole-edition coverage. Both the
legacy projection and its raw authorities are replayed before normal staging.
"""
import argparse
from datetime import datetime
from pathlib import Path
import re
import sys

sys.dont_write_bytecode = True
import prepare_file_metadata as evidence
import prepare_file_metadata_v2 as metadata
import prepare_site_info as site_info

MAX_RESPONSE = metadata.MAX_RESPONSE
MAX_METADATA = metadata.MAX_METADATA
MAX_TITLES = metadata.MAX_TITLES
digest, encoded, small, decode = evidence.digest, evidence.encoded, evidence.small, evidence.decode
require_edition, wiktionary_api = evidence.require_edition, evidence.wiktionary_api
classify_response = metadata.classify_response


def producer():
    return {"generator_sha256": digest(small(Path(__file__)))}


# Build-only, offline figure authority. This does not classify handlers by MIME
# or change the v1/v2 file metadata transport or Lua host ABI.
FIGURE_SIZING_SCHEMA = 'wikidict.figure-sizing-source.v1'
FIGURE_SOURCE_PROFILES = {'0470f6c99a6456a366635bf25a517a1f951de6f5': {'kind': 'wikimedia-imagehandler-v3',
                                              'site_family': 'wikimedia-wiktionary',
                                              'handler_families': {'image/svg+xml': {'handler_class': 'MediaWiki\\Media\\SvgHandler', 'mediatype': 'DRAWING'},
                                                                   'image/svg': {'handler_class': 'MediaWiki\\Media\\SvgHandler', 'mediatype': 'DRAWING'},
                                                                   'image/jpeg': {'handler_class': 'MediaWiki\\Media\\JpegHandler', 'mediatype': 'BITMAP'},
                                                                   'image/png': {'handler_class': 'MediaWiki\\Media\\PNGHandler', 'mediatype': 'BITMAP'},
                                                                   'image/tiff': {'handler_class': 'MediaWiki\\Extension\\PagedTiffHandler\\PagedTiffHandler', 'mediatype': 'BITMAP'}},
                                              'png_handler_sha256': '47de6d86c665bfcce949a4199d05842a6bf3d8a39cd97af280b7c0a857a86840',
                                              'paged_tiff_handler_sha256': 'b7b733e254f248f0ef2f196a38675700ef3837b41ce26b96bff0d32cc9f8e6c5',
                                              'paged_tiff_image_sha256': '2de8768338aaa885d38fabb04c4f844fa2bf1910dc6cf914fb2d65f8e0b41e45',
                                              'local_file_sha256': '193d8640f2e75995741767e1d80ea319f97222b10a76b0748c63f9b8d7343354',
                                              'foreign_api_file_sha256': '319fd927464b5e0b633ed0386061f051a30ac87ebf2524ce275d89ddcbecf746',
                                              'jpeg_handler_sha256': 'be3aeaab237907ea751c5d5c99ac4c039c40ca0d1c4476a7d6fcfb4f86daf6eb',
                                              'exif_bitmap_handler_sha256': 'e50838b284c4a0dc013da4a405bf568144c9f63e9bd162e19da79f2dbc9f4f45',
                                              'bitmap_handler_sha256': 'd479a959113ddeb55d07ba5607d4a06c52010cba60b616544fcc0800aaab2ce4',
                                              'transformational_image_handler_sha256': '8abe6f37493ed21944d20385e433a0091e8c8e6b019216b41edc849a13df9970',
                                              'imageinfo_api_sha256': 'e86d5021447684f9bc6f56140a16f6f0a117b8d752ef678b37e66553512318b5',
                                              'linker_sha256': '202965a43866f0bc5a2ed0f0aaa898dfb27fc91a9a78b6f205ba5f16beea96f5',
                                              'image_handler_sha256': '2e4b6fd849ff0eddbf01163229305c899ab620b75e21f1c48ca63b53c0a84696',
                                              'media_handler_sha256': 'a56e9e26bb3152b524971b5bc9d9078c1f7ec3741777e32dc7c93d0cf2f1ce96',
                                              'file_sha256': '45f446888af647f1b175f43580daae9cf9393883c04c30af743821647b681396',
                                              'svg_handler_sha256': 'f3e8b5c497c8ed3871e89edb23ca19c8279caf93a6697f2b9431a562204637a9',
                                              'handler_factory_sha256': '70a1e42eea69913af2435f68ddd31b8ba6acf0e0e02abf4573e2792a11c42461',
                                              'service_wiring_sha256': '784aed3e7d2d205cdfab25c99c9952859fbbb0dcb1e8ac17cde470e72b1a9571',
                                              'wmf_common_sha256': '1390345238dac0e6fe034d5645ce240d82207f27d8e445255dbd6ceabbcf4d17',
                                              'wmf_initialise_sha256': '438a10cf3567c592cd1504722b5c86f810786952d15b7495e003fc24dfee8aff',
                                              'paged_tiff_manifest_sha256': '09662c0816af5f534b540582f3fdf50486673433b48b164e63ad14097f0848eb',
                                              'timed_media_manifest_sha256': '46a14f5dabc9ff8d064854ed8e6ab5103cf0aa29927ce69a36744c0370e1f639',
                                              'pdf_manifest_sha256': '97ccd0e0302cd0d2b33a4b04afb7c44ba933f75ce984aa21402baa7e8450d6da',
                                              'three_d_manifest_sha256': 'ee490e501725afa14926147c61c2ee89c3e320f4d6824703f0306bd5d5d0c10b',
                                              'timed_media_registration_sha256': 'a3bea9ce1ce5026b983fa1f3a528f9560d02e152996151dc22d2e18320d94da9',
                                              'timed_media_presets_sha256': '06c3e0c9a65d840d0d8e391389b3b0986699b57c3a9836af1bd6a76b8d6d8529',
                                              'timed_media_namespaces_sha256': 'a1043b29b314adb045baa66faefaf007238ae2411297760c33ced75cfcf39ed2',
                                              'media_extensions': {'PagedTiffHandler': '053e6a37f77c35fb19a7adb699fdc87af137cc41',
                                                                   'TimedMediaHandler': '2d3ee29044041c34a456981b50ad53e87bc12c6a',
                                                                   'PDF Handler': '23541e678a77dae376ab9a4693fc6c624d8103ff',
                                                                   '3D': '59f36a91e568500d404a01feef4290dafa008002'}}}
FIGURE_SOURCE_FILES = {'png_handler_sha256': 'png-tiff-source198/PNGHandler.0470.php',
 'paged_tiff_handler_sha256': 'png-tiff-source198/PagedTiffHandler.053e6a37f77c.php',
 'paged_tiff_image_sha256': 'png-tiff-source198/PagedTiffImage.053e6a37f77c.php',
 'local_file_sha256': 'png-tiff-source198/LocalFile.0470.php',
 'foreign_api_file_sha256': 'png-tiff-source198/ForeignAPIFile.0470.php',
 'jpeg_handler_sha256': 'JpegHandler.0470.php',
 'exif_bitmap_handler_sha256': 'ExifBitmapHandler.0470.php',
 'bitmap_handler_sha256': 'BitmapHandler.0470.php',
 'transformational_image_handler_sha256': 'TransformationalImageHandler.0470.php',
 'imageinfo_api_sha256': 'ApiQueryImageInfo.0470.php',
 'linker_sha256': '0470-Linker.php',
 'image_handler_sha256': 'ImageHandler.0470.php',
 'media_handler_sha256': 'MediaHandler.0470.php',
 'file_sha256': 'File.0470.php',
 'svg_handler_sha256': 'SvgHandler.0470.php',
 'handler_factory_sha256': 'MediaHandlerFactory.0470.php',
 'service_wiring_sha256': 'ServiceWiring.php.0470',
 'wmf_common_sha256': 'CommonSettings.php.38b99ce210bb',
 'wmf_initialise_sha256': 'InitialiseSettings.php.38b99ce210bb',
 'paged_tiff_manifest_sha256': 'PagedTiffHandler.053e6a37f77c.extension.json',
 'timed_media_manifest_sha256': 'TimedMediaHandler.2d3ee2904404.extension.json',
 'pdf_manifest_sha256': 'PdfHandler.23541e678a77.extension.json',
 'three_d_manifest_sha256': '3D.59f36a91e568.extension.json',
 'timed_media_registration_sha256': 'TimedMediaHandler.2d3ee2904404.RegistrationCallback.php',
 'timed_media_presets_sha256': 'TimedMediaHandler.2d3ee2904404.TranscodePresets.php',
 'timed_media_namespaces_sha256': 'TimedMediaHandler.2d3ee2904404.namespaces.php'}


def _figure_utc_key(value):
    """Canonical API UTC instant, preserving fractional precision exactly."""
    match = re.fullmatch(r'([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(?:\.([0-9]+))?Z', value) if isinstance(value, str) else None
    if match is None:
        raise ValueError('Noncanonical figure source UTC timestamp')
    base = match.group(1)
    datetime.strptime(base, '%Y-%m-%dT%H:%M:%S')
    # Fixed-width calendar base sorts chronologically. Decimal digit strings
    # compare exactly after insignificant trailing zeros are removed.
    return base, (match.group(2) or '').rstrip('0')


def _figure_site_profile(site_raw, general, wiki, source_profile, approved):
    if (not isinstance(source_profile, dict)
            or set(source_profile) != set(approved) | {'site_raw_sha256'}
            or {key: value for key, value in source_profile.items() if key != 'site_raw_sha256'} != approved
            or source_profile['site_raw_sha256'] != digest(site_raw)):
        raise ValueError('Unreviewed or changed figure sizing source profile')
    site = decode(site_raw)
    require_edition(site, wiki)
    if any(key in site for key in ('error', 'errors', 'warnings')):
        raise ValueError('Unknown figure site registration evidence')
    official = wiktionary_api(wiki).removesuffix('/w/api.php')
    other = site['query']['general']
    accepted_servers = (official, official.removeprefix('https:'))
    if (general.get('server') not in accepted_servers or other.get('server') not in accepted_servers
            or other.get('git-hash') != general.get('git-hash')
            or other.get('lang') != general.get('lang')):
        raise ValueError('Figure handler profile belongs to a different site or core')
    observed = site.get('curtimestamp')
    if not isinstance(observed, str) or not re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z', observed):
        raise ValueError('Missing actual site registration observation time')
    datetime.strptime(observed, '%Y-%m-%dT%H:%M:%SZ')
    extensions = site['query'].get('extensions')
    if not isinstance(extensions, list) or len(extensions) > 1024:
        raise ValueError('Invalid site extension evidence inventory')
    registered = {}
    for extension in extensions:
        if not isinstance(extension, dict):
            raise ValueError('Invalid site extension evidence')
        if extension.get('type') != 'media':
            continue
        name, revision = extension.get('name'), extension.get('vcs-version')
        if (not isinstance(name, str) or name in registered or not isinstance(revision, str)
                or not re.fullmatch('[0-9a-f]{40}', revision)):
            raise ValueError('Conflicting media registration evidence')
        registered[name] = revision
    if registered != approved['media_extensions']:
        raise ValueError('Unreviewed media registration set or version')


def _figure_metadata_map(items):
    """Decode only the API metadata list shape, rejecting ambiguous keys."""
    if not isinstance(items, list) or len(items) > 4096:
        raise ValueError('Invalid single-page TIFF metadata')
    result = {}
    for item in items:
        if (not isinstance(item, dict) or set(item) != {'name', 'value'}
                or type(item['name']) is not str or item['name'] in result):
            raise ValueError('Invalid single-page TIFF metadata')
        result[item['name']] = item['value']
    return result


def _figure_tiff_page_axes(info, width, height):
    """The admitted subset has one exact page1, matching API and handler axes."""
    if type(info.get('pagecount')) is not int or info['pagecount'] != 1:
        raise ValueError('Unproved single-page TIFF axes')
    metadata = _figure_metadata_map(info.get('metadata'))
    if ('errors' in metadata or '_error' in metadata
            or metadata.get('TIFF_METADATA_VERSION') != '1.4'):
        raise ValueError('Unproved single-page TIFF axes')
    for key in ('page_count', 'first_page', 'last_page'):
        if type(metadata.get(key)) is not int or metadata[key] != 1:
            raise ValueError('Unproved single-page TIFF axes')
    pages = metadata.get('page_data')
    if (not isinstance(pages, list) or len(pages) != 1
            or not isinstance(pages[0], dict) or set(pages[0]) != {'name', 'value'}):
        raise ValueError('Unproved single-page TIFF axes')
    page_key = pages[0]['name']
    if not ((type(page_key) is int and page_key == 1)
            or (type(page_key) is str and page_key == '1')):
        raise ValueError('Unproved single-page TIFF axes')
    page = _figure_metadata_map(pages[0]['value'])
    for key, expected in (('page', 1), ('width', width), ('height', height)):
        if type(page.get(key)) is not int or page[key] != expected:
            raise ValueError('Unproved single-page TIFF axes')


def figure_sizing_document(raw, namespace_raw, wiki, date, requests, source_profile, site_raw):
    """Replay one same-response source; certify only explicit requested tuples.

    The proof is width-bound and branch independent: no SVG/raster, rotation,
    configuration, thumbnail backing-size or historical-epoch inference.
    """
    if len(raw) > MAX_RESPONSE or len(site_raw) > MAX_RESPONSE or len(namespace_raw) > MAX_METADATA:
        raise ValueError('Figure sizing source exceeds bounded capacity')
    data = decode(raw)
    require_edition(data, wiki)
    general = data['query']['general']
    core = general.get('git-hash')
    if not isinstance(core, str) or not re.fullmatch('[0-9a-f]{40}', core):
        raise ValueError('Invalid figure sizing core identity')
    approved = FIGURE_SOURCE_PROFILES.get(core)
    if approved is None:
        raise ValueError('Unreviewed figure sizing source core')
    _figure_site_profile(site_raw, general, wiki, source_profile, approved)
    language = general.get('lang')
    if not isinstance(language, str) or not re.fullmatch('[A-Za-z0-9-]+', language):
        raise ValueError('Missing figure sizing content language')
    if ('# content-language\t' + language) not in namespace_raw.decode('utf-8').splitlines():
        raise ValueError('Figure sizing namespace language mismatch')
    observed = data.get('curtimestamp')
    if not isinstance(observed, str) or not re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z', observed):
        raise ValueError('Missing same-response figure observation time')
    datetime.strptime(observed, '%Y-%m-%dT%H:%M:%SZ')
    registry = evidence.Registry(namespace_raw, wiki, date)
    if not isinstance(requests, list) or not 1 <= len(requests) <= MAX_TITLES:
        raise ValueError('Invalid figure sizing occurrence inventory')
    checked, seen, titles, title_seen = [], set(), [], set()
    for request in requests:
        if not isinstance(request, dict) or set(request) != {'canonical_file', 'format', 'width_px', 'height_px'}:
            raise ValueError('Invalid figure sizing occurrence fields')
        name = request['canonical_file']
        if (not isinstance(name, str) or registry.file_title(name) != name
                or any(c in name for c in '\t\r\n\0')):
            raise ValueError('Noncanonical or unsafe figure file')
        width, height = request['width_px'], request['height_px']
        if (request['format'] != 'thumbnail' or type(width) is not int
                or not 0 < width < 2**32 or height is not None):
            raise ValueError('Occurrence has no branch-independent width proof')
        key = (name, request['format'], width, height)
        if key in seen:
            raise ValueError('Duplicate normalized figure sizing occurrence')
        seen.add(key)
        checked.append(dict(request))
        if name not in title_seen:
            title_seen.add(name)
            titles.append(name)
    rows = classify_response(data, titles, registry)
    records = []
    pages = {page['title']: page for page in data['query']['pages']}
    for request in checked:
        row = rows[request['canonical_file']]
        if not row['exists']:
            raise ValueError('Figure request is not proved by the source original axes')
        info = pages[row['response_title']]['imageinfo'][0]
        mime = info.get('mime')
        family = approved['handler_families'].get(mime) if isinstance(mime, str) else None
        if (family is None or row['mediatype'] != family['mediatype']
                or row['canonicaltitle'] != request['canonical_file']
                or row['width'] <= 0 or row['height'] <= 0
                or request['width_px'] > row['width']
                or _figure_utc_key(row['file_timestamp']) > _figure_utc_key(observed)):
            raise ValueError('Figure request is not proved by the source original axes')
        if mime == 'image/tiff':
            _figure_tiff_page_axes(info, row['width'], row['height'])
        records.append({**request, 'file_sha1': row['file_sha1'],
            'file_timestamp': row['file_timestamp'], 'original_width': row['width'],
            'original_height': row['height'], 'sizing': 'requested_fit',
            'proof_kind': 'thumbnail-width-not-above-original'})
    records.sort(key=lambda row: (row['canonical_file'].encode('utf-8'), row['width_px']))
    result = {'schema': FIGURE_SIZING_SCHEMA, 'wiki': wiki,
        'content_language': language, 'core_revision': core,
        'namespace_registry_sha256': digest(namespace_raw),
        'observation_utc': observed, 'raw_sha256': digest(raw),
        'generator_sha256': producer()['generator_sha256'],
        'source_profile': dict(source_profile), 'records': records}
    if len(encoded(result)) > MAX_METADATA:
        raise ValueError('Figure sizing projection exceeds bounded capacity')
    return result


def verify_figure_sizing_document(projection, raw, namespace_raw, wiki, date, requests, source_profile, site_raw):
    """Semantic replay still rejects a coherently rehashed false projection."""
    if not isinstance(projection, dict):
        raise ValueError('Invalid figure sizing projection')
    identity = projection.get('generator_sha256')
    if not isinstance(identity, str) or not re.fullmatch('[0-9a-f]{64}', identity):
        raise ValueError('Invalid figure sizing generator identity')
    expected = figure_sizing_document(raw, namespace_raw, wiki, date, requests, source_profile, site_raw)
    # Recorded identity is provenance; current semantic replay is the proof.
    expected['generator_sha256'] = identity
    if encoded(projection) != encoded(expected):
        raise ValueError('Figure sizing projection differs from exact source replay')
    return projection


SCHEMA = 'wikidict.figure-inputs.v1'
MANIFEST = 'figure-inputs.manifest.json'
COMPLETE = 'figure-inputs.complete.json'
ROLES = {
    'figure-siteinfo': 'figure-siteinfo.raw.json',
    'figure-sizing': 'figure-sizing.json',
    'figure-sizing-raw': 'figure-sizing.raw.json',
    'figure-sizing-site': 'figure-sizing.site.json',
}
REQUESTS = 'figure-sizing.requests.json'
PROJECTION = 'figure-sizing.projection.json'
LEGACY_GENERATOR = '445969d476e9e7d5cfa725b74900b3e80b950cfb85eed9a70d3ed7afe85fb2a3'


def payload(root):
    result = {}
    for path in sorted(Path(root).iterdir()):
        if path.name in (MANIFEST, COMPLETE):
            continue
        raw = small(path, MAX_METADATA)
        result[path.name] = {'bytes': len(raw), 'sha256': digest(raw)}
    return result


def replay(root, wiki, date):
    """Replay original source captures, retaining their exact finite scope."""
    root = Path(root)
    defaults = site_info.verify(root, embedded=True)
    if (defaults['wiki'] != wiki or defaults['date'] != date or
            defaults['profile'] != site_info.FIGURE_PROFILE):
        raise ValueError('Figure defaults require the matching captured default-options profile')
    namespace = small(root / (site_info.PREFIX + 'namespace-registry.tsv'))
    default_raw = small(root / ROLES['figure-siteinfo'], MAX_RESPONSE)
    if default_raw != small(root / site_info.SNAPSHOT, MAX_RESPONSE):
        raise ValueError('Figure defaults differ from the authenticated site-info capture')
    default_data = decode(default_raw)
    general = default_data['query']['general']
    if type(general.get('rtl')) is not bool:
        raise ValueError('Figure defaults lack explicit source direction')
    site_info.figure_thumbnail_width(default_data['query'])
    projection_raw = small(root / ROLES['figure-sizing'])
    projection = decode(projection_raw)
    raw = small(root / ROLES['figure-sizing-raw'], MAX_RESPONSE)
    site_raw = small(root / ROLES['figure-sizing-site'], MAX_RESPONSE)
    requests_raw = small(root / REQUESTS)
    requests = decode(requests_raw)
    if (not isinstance(projection, dict) or projection.get('schema') != FIGURE_SIZING_SCHEMA or
            projection.get('generator_sha256') != LEGACY_GENERATOR or
            projection.get('core_revision') != general.get('git-hash')):
        raise ValueError('Unreviewed or mismatched Figure projection source')
    verify_figure_sizing_document(projection, raw, namespace, wiki, date,
                                 requests, projection.get('source_profile'), site_raw)
    authority = decode(small(root / PROJECTION))
    if not isinstance(authority, dict) or not isinstance(authority.get('inputs'), dict):
        raise ValueError('Invalid Figure projection authority')
    expected_sources = {name: projection['source_profile'][role]
                        for role, name in FIGURE_SOURCE_FILES.items()}
    inputs = authority['inputs']
    sources = inputs.get('sources', {})
    if (authority.get('schema') != FIGURE_SIZING_SCHEMA + '.projection' or
            authority.get('temporal_scope') != 'fresh-current-api-observation-not-historical-equivalence' or
            inputs.get('api_response_sha256') != digest(raw) or
            inputs.get('namespace_registry_sha256') != digest(namespace) or
            inputs.get('requests_sha256') != digest(requests_raw) or
            not isinstance(sources, dict) or set(sources) != set(expected_sources)):
        raise ValueError('Figure projection input authority differs')
    for name, expected in expected_sources.items():
        row = sources[name]
        if (not isinstance(row, dict) or row.get('sha256') != expected or
                type(row.get('bytes')) is not int or row['bytes'] <= 0):
            raise ValueError('Figure projection primary source differs: ' + name)
    for key, filename, data in (('output', ROLES['figure-sizing'], projection_raw),
                                ('raw', ROLES['figure-sizing-raw'], raw),
                                ('site', ROLES['figure-sizing-site'], site_raw)):
        if authority.get(key) != {'path': filename, 'bytes': len(data), 'sha256': digest(data)}:
            raise ValueError('Figure projection artifact authority differs: ' + filename)
    files = {request['canonical_file'] for request in requests}
    coverage = {'kind': 'selected-occurrences', 'whole_edition': False,
                'files': len(files), 'occurrences': len(requests),
                'requests_sha256': digest(requests_raw)}
    expected_files = {*defaults['artifacts'], site_info.MANIFEST, site_info.COMPLETE,
                      *ROLES.values(), REQUESTS, PROJECTION}
    if set(payload(root)) != expected_files:
        raise ValueError('Unexpected or incomplete Figure evidence inventory')
    return defaults, coverage


def verify(root, require_complete=True):
    root = Path(root)
    if root.is_symlink() or not root.is_dir():
        raise ValueError('Unsafe Figure capture directory')
    manifest_raw = small(root / MANIFEST)
    manifest = decode(manifest_raw)
    if (not isinstance(manifest, dict) or manifest.get('schema') != SCHEMA or
            not isinstance(manifest.get('generator_sha256'), str) or
            re.fullmatch('[0-9a-f]{64}', manifest['generator_sha256']) is None):
        raise ValueError('Invalid Figure capture manifest')
    if require_complete and decode(small(root / COMPLETE)) != {
            'schema': SCHEMA, 'manifest_sha256': digest(manifest_raw)}:
        raise ValueError('Incomplete Figure capture')
    defaults, coverage = replay(root, manifest.get('wiki'), manifest.get('date'))
    if (manifest.get('namespace_registry_sha256') != defaults['namespace_registry_sha256'] or
            manifest.get('coverage') != coverage or manifest.get('artifacts') != payload(root) or
            manifest.get('outputs') != {name: digest(small(root / filename)) for name, filename in ROLES.items()}):
        raise ValueError('Figure capture differs from source replay')
    return manifest


def validate_snapshot(path, wiki=None, date=None):
    path = Path(path)
    if path.name not in ROLES.values():
        raise ValueError('Unexpected Figure snapshot filename')
    manifest = verify(path.parent)
    if (wiki is not None and manifest['wiki'] != wiki) or (date is not None and manifest['date'] != date):
        raise ValueError('Figure capture edition/date mismatch')
    role = next(name for name, filename in ROLES.items() if filename == path.name)
    return {**manifest, 'output_sha256': manifest['outputs'][role]}


def verify_tuple(paths, wiki=None, date=None):
    """One semantic replay for one invocation-local, complete source tuple."""
    if set(paths) != set(ROLES):
        raise ValueError('Incomplete Figure source tuple')
    parents = set()
    for role, path in paths.items():
        path = Path(path)
        if path.name != ROLES[role] or path.is_symlink():
            raise ValueError('Unexpected Figure role path')
        parents.add(path.parent)
    if len(parents) != 1:
        raise ValueError('Figure input roles belong to different source captures')
    root = parents.pop()
    manifest_raw = small(root / MANIFEST)
    manifest = verify(root)
    if (wiki is not None and manifest['wiki'] != wiki) or (date is not None and manifest['date'] != date):
        raise ValueError('Figure capture edition/date mismatch')
    # Recheck every immutable source byte after the semantic replay. The local
    # result may be shared only by these four roles at this boundary.
    marker_raw = encoded({'schema': SCHEMA, 'manifest_sha256': digest(manifest_raw)})
    if (small(root / MANIFEST) != manifest_raw or decode(manifest_raw) != manifest or
            payload(root) != manifest['artifacts'] or small(root / COMPLETE) != marker_raw):
        raise ValueError('Figure source capture changed during validation')
    inventory = {**{name: row['sha256'] for name, row in manifest['artifacts'].items()},
                 MANIFEST: digest(manifest_raw), COMPLETE: digest(marker_raw)}
    return {role: ({**manifest, 'output_sha256': manifest['outputs'][role]}, dict(inventory))
            for role in ROLES}


def capture_artifacts(path, manifest=None):
    validated = validate_snapshot(path)
    if manifest is not None and validated != manifest:
        raise ValueError('Figure capture changed during pinning')
    return {**{name: row['sha256'] for name, row in validated['artifacts'].items()},
            MANIFEST: digest(small(Path(path).with_name(MANIFEST))),
            COMPLETE: digest(small(Path(path).with_name(COMPLETE)))}


def stage(args):
    """Package already captured source evidence. No HTTP or source expansion."""
    root = Path(args.output)
    projection_root = Path(args.projection)
    if projection_root.is_symlink() or not projection_root.is_dir():
        raise ValueError('Unsafe Figure projection directory')
    for source in (Path(args.defaults), projection_root):
        if root.resolve().is_relative_to(source.resolve()):
            raise ValueError('Figure staging cannot modify a retained input directory')
    defaults_path = Path(args.defaults) / site_info.SNAPSHOT
    defaults = site_info.validate_snapshot(defaults_path, args.wiki, args.date)
    if defaults['profile'] != site_info.FIGURE_PROFILE:
        raise ValueError('Missing Figure default-options capture; general site-info is insufficient')
    artifacts = site_info.capture_artifacts(defaults_path, defaults)
    saved = {name: small(defaults_path.with_name(name), MAX_METADATA) for name in artifacts}
    for name, expected in artifacts.items():
        if digest(saved[name]) != expected:
            raise ValueError('Figure defaults changed while packaging')
    for filename in (*list(ROLES.values())[1:], PROJECTION):
        saved[filename] = small(projection_root / filename, MAX_METADATA)
    saved[REQUESTS] = small(args.requests)
    saved[ROLES['figure-siteinfo']] = saved[site_info.SNAPSHOT]
    root.mkdir(parents=True, exist_ok=False)
    for name, raw in saved.items():
        evidence.put(root / name, raw)
    _, coverage = replay(root, args.wiki, args.date)
    manifest = {'schema': SCHEMA, **producer(), 'wiki': args.wiki, 'date': args.date,
                'namespace_registry_sha256': defaults['namespace_registry_sha256'],
                'coverage': coverage, 'artifacts': payload(root),
                'outputs': {role: digest(saved[name]) for role, name in ROLES.items()}}
    evidence.document(root / MANIFEST, manifest)
    verify(root, require_complete=False)
    evidence.document(root / COMPLETE, {'schema': SCHEMA, 'manifest_sha256': digest(small(root / MANIFEST))})
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    check = commands.add_parser('verify')
    check.add_argument('output', type=Path)
    prepare = commands.add_parser('stage', help='offline replay of retained source captures')
    for name in ('wiki', 'date'):
        prepare.add_argument('--' + name, required=True)
    for name in ('defaults', 'projection', 'requests', 'output'):
        prepare.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    result = stage(args) if args.command == 'stage' else verify(args.output)
    print(encoded({key: result[key] for key in ('schema', 'wiki', 'date', 'coverage')}).decode(), end='')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError) as error:
        raise SystemExit(str(error)) from error


