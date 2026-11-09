#!/usr/bin/env python3
"""Replay and stage source-backed Figure inputs and bounded file inventories.

A finite occurrence capture never implies whole-edition coverage. Both the
legacy projection and its raw authorities are replayed before normal staging.
"""
import argparse
from datetime import datetime
import fcntl
import gzip
import hashlib
import itertools
import json
import math
import os
from pathlib import Path
import re
import stat
import sys
import time
from urllib.parse import parse_qsl, urlsplit

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


# The exact handler/File/Linker/API/service sources and media registrations are
# identical at these reviewed revisions. Defaults retain their own observation and
# core identity; this does not replace their captured values with newer ones.
FIGURE_COMPATIBLE_CORE = 'ead780177c5a02aa63ac6fd3a50977df9719fe63'
FIGURE_CURRENT_CORE = 'f45897451256aa3799aecc5d7ee320ade22beaec'
for _reviewed_core in (FIGURE_COMPATIBLE_CORE, FIGURE_CURRENT_CORE):
    FIGURE_SOURCE_PROFILES[_reviewed_core] = dict(FIGURE_SOURCE_PROFILES['0470f6c99a6456a366635bf25a517a1f951de6f5'])


def figure_source_compatible(left, right):
    return left == right or (left in FIGURE_SOURCE_PROFILES and right in FIGURE_SOURCE_PROFILES)


def observed_svg_width(info, mime, mediatype, width, height):
    """Certify one observed rasterized SVG client width, never all upscales.

    SvgHandler's client-scaling branch retains the original URL base; File's
    request provenance changes only its query. A different returned base plus
    exact client dimensions proves this observation took the rasterized branch.
    Bitmap, incomplete, native-client and inconsistent observations add no grant.
    """
    if mime not in ('image/svg+xml', 'image/svg') or mediatype != 'DRAWING' or width <= 0 or height <= 0:
        return None
    if any(key in info for key in ('thumberror', 'filehidden', 'suppressed', 'filemissing')):
        return None
    observed, observed_height = info.get('thumbwidth'), info.get('thumbheight')
    if (type(observed) is not int or not width < observed < 2**32 or
            type(observed_height) is not int or not 0 < observed_height < 2**32 or
            observed_height != (height * observed + width // 2) // width):
        return None
    attributes = info.get('thumbattribs')
    if (not isinstance(attributes, dict) or type(attributes.get('width')) is not int or
            type(attributes.get('height')) is not int or attributes['width'] != observed or
            attributes['height'] != observed_height):
        return None
    def base(value):
        if (not isinstance(value, str) or not value.startswith('https://') or
                any(ord(char) <= 32 or ord(char) == 127 for char in value) or '#' in value or '\\' in value):
            return None
        value = value.split('?', 1)[0]
        host, separator, path = value[8:].partition('/')
        if not separator or not host or not path or '@' in host or ':' in host:
            return None
        return value
    original, thumbnail = base(info.get('url')), base(info.get('thumburl'))
    if original is None or thumbnail is None or original == thumbnail:
        return None
    return observed


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
FILES_SCHEMA = 'wikidict.figure-sizing-files.v1'
RAW_BATCHES_SCHEMA = 'wikidict.figure-sizing-raw-batches.v1'
MAX_BATCHES = 10000
FILES_STREAM_SCHEMA = 'wikidict.figure-sizing-files.stream.v1'
RAW_STREAM_SCHEMA = 'wikidict.figure-sizing-raw.stream.v1'
STREAM_HEADER_LIMIT = 2 * 1024 * 1024
STREAM_RAW_LINE_LIMIT = 16 * 1024 * 1024
STREAM_FACT_LINE_LIMIT = 64 * 1024
STREAM_COUNTS = ('records_count', 'base_batches', 'observed_batches')
STREAM_COMMON = ('wiki', 'core_revision', 'namespace_registry_sha256', *STREAM_COUNTS)


def stream_encoded(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True,
                       separators=(',', ':'), allow_nan=False) + '\n').encode('utf-8')


def stream_decode(raw):
    if (not raw.endswith(b'\n') or raw == b'\n' or b'\r' in raw or
            raw.startswith(b'\xef\xbb\xbf')):
        raise ValueError('Figure stream requires complete nonempty UTF-8 LF records')
    def nonfinite(value):
        raise ValueError('Nonfinite Figure stream number: '+value)
    def finite_float(value):
        parsed = float(value)
        if not math.isfinite(parsed):
            nonfinite(value)
        return parsed
    value = json.loads(raw.decode('utf-8'), object_pairs_hook=evidence.unique_object,
                       parse_constant=nonfinite, parse_float=finite_float)
    if not isinstance(value, dict):
        raise ValueError('Figure stream records must be objects')
    return value


def validate_stream_header(header, schema, file_bytes):
    fields = {'schema', *STREAM_COMMON}
    if schema == FILES_STREAM_SCHEMA:
        fields.update(('content_language', 'raw_sha256', 'generator_sha256', 'source_profile', 'raw_bytes'))
    elif schema != RAW_STREAM_SCHEMA:
        raise ValueError('Unknown Figure stream schema')
    if set(header) != fields or header['schema'] != schema:
        raise ValueError('Invalid Figure stream header fields')
    for name in (*STREAM_COUNTS, *(['raw_bytes'] if schema == FILES_STREAM_SCHEMA else [])):
        if type(header[name]) is not int or not 0 <= header[name] < 2**64:
            raise ValueError('Invalid Figure stream count or byte length')
    count, base, observed = (header[name] for name in STREAM_COUNTS)
    if not base <= count <= 50 * base or observed > count or base + observed > 0xffffffff:
        raise ValueError('Impossible Figure stream record/batch counts')
    rows = count if schema == FILES_STREAM_SCHEMA else base + observed
    if rows > file_bytes:
        raise ValueError('Figure stream count exceeds its actual file size')
    for name, size in (('core_revision', 40), ('namespace_registry_sha256', 64),
                       *((('raw_sha256', 64), ('generator_sha256', 64)) if schema == FILES_STREAM_SCHEMA else ())):
        if not isinstance(header[name], str) or re.fullmatch('[0-9a-f]{'+str(size)+'}', header[name]) is None:
            raise ValueError('Invalid Figure stream source identity')
    if not isinstance(header['wiki'], str):
        raise ValueError('Invalid Figure stream wiki')
    evidence.wiktionary_api(header['wiki'])
    if schema == FILES_STREAM_SCHEMA:
        if not isinstance(header['content_language'], str) or not header['content_language']:
            raise ValueError('Invalid Figure stream language')
        if (count == 0) != (header['source_profile'] is None):
            raise ValueError('Empty Figure stream cannot claim handler authority')
    return rows


def stream_values(path, schema):
    """Yield the header and exact declared records with bounded transient input."""
    path = Path(path)
    before = evidence.stamp(path)
    with path.open('rb') as source:
        raw = source.readline(STREAM_HEADER_LIMIT + 1)
        if len(raw) > STREAM_HEADER_LIMIT:
            raise ValueError('Figure stream header exceeds its bound')
        header = stream_decode(raw)
        count = validate_stream_header(header, schema, before[2] - len(raw))
        yield header
        limit = STREAM_RAW_LINE_LIMIT if schema == RAW_STREAM_SCHEMA else STREAM_FACT_LINE_LIMIT
        for _ in range(count):
            raw = source.readline(limit + 1)
            if len(raw) > limit:
                raise ValueError('Figure stream record exceeds its bound')
            yield stream_decode(raw)
        if source.read(1):
            raise ValueError('Trailing Figure stream records or bytes')
    if evidence.stamp(path) != before:
        raise ValueError('Figure stream changed during replay')


def figure_stream_document(raw_path, namespace_raw, wiki, date, site_raw):
    before = evidence.stamp(Path(raw_path))
    values = stream_values(raw_path, RAW_STREAM_SCHEMA)
    header = next(values)
    result = file_records(values, namespace_raw, wiki, date, site_raw,
                          has_batches=bool(header['base_batches']), record_limit=header['records_count'])
    for name in ('wiki', 'core_revision', 'namespace_registry_sha256', 'base_batches', 'observed_batches'):
        if result[name] != header[name]:
            raise ValueError('Figure raw stream differs from its declared identity or counts')
    if len(result['records']) != header['records_count']:
        raise ValueError('Figure raw stream has incomplete file membership')
    identity = evidence.fingerprint(Path(raw_path))
    if evidence.stamp(Path(raw_path)) != before:
        raise ValueError('Figure raw stream changed before hashing')
    result.update(schema=FILES_STREAM_SCHEMA, records_count=len(result['records']),
                  raw_bytes=identity['size'], raw_sha256=identity['sha256'],
                  generator_sha256=producer()['generator_sha256'])
    return result


def write_projection_stream(path, document):
    header = {key: value for key, value in document.items() if key != 'records'}
    validate_stream_header(header, FILES_STREAM_SCHEMA, 2**64-1)
    with Path(path).open('xb') as output:
        raw = stream_encoded(header)
        if len(raw) > STREAM_HEADER_LIMIT:
            raise ValueError('Figure projection header exceeds its bound')
        output.write(raw)
        previous = None
        for record in document['records']:
            key = record['requested_file'].encode('utf-8')
            if previous is not None and key <= previous:
                raise ValueError('Figure projection records are not strictly ordered')
            previous = key
            raw = stream_encoded(record)
            if len(raw) > STREAM_FACT_LINE_LIMIT:
                raise ValueError('Figure projection record exceeds its bound')
            output.write(raw)


def verify_stream_document(projection_path, raw_path, namespace_raw, wiki, date, site_raw):
    expected = figure_stream_document(raw_path, namespace_raw, wiki, date, site_raw)
    values = stream_values(projection_path, FILES_STREAM_SCHEMA)
    header = next(values)
    expected_header = {key: value for key, value in expected.items() if key != 'records'}
    expected_header['generator_sha256'] = header['generator_sha256']
    if header != expected_header:
        raise ValueError('Figure projection stream header differs from exact raw replay')
    for record in expected['records']:
        if next(values) != record:
            raise ValueError('Figure projection stream record differs from exact raw replay')
    if next(values, None) is not None:
        raise ValueError('Figure projection has unexpected trailing records')
    return expected


def file_fact_identity(record):
    return tuple(record[key] for key in ('canonical_file', 'state', 'file_sha1',
        'file_timestamp', 'original_width', 'original_height', 'mime', 'mediatype'))


def file_records(batches, namespace_raw, wiki, date, site_raw, *, has_batches, record_limit):
    registry = evidence.Registry(namespace_raw, wiki, date)
    registration = decode(site_raw)
    require_edition(registration, wiki)
    site_general = registration['query']['general']
    core = site_general.get('git-hash')
    language = site_general.get('lang')
    if (not isinstance(core, str) or re.fullmatch('[0-9a-f]{40}', core) is None or
            not isinstance(language, str) or '# content-language\t'+language not in namespace_raw.decode().splitlines()):
        raise ValueError('Figure file site/namespace identity mismatch')
    profile = None
    if has_batches:
        approved = FIGURE_SOURCE_PROFILES.get(core)
        if approved is None:
            raise ValueError('Unreviewed Figure handler source version; retain the response for source reconciliation')
        profile = dict(approved, site_raw_sha256=digest(site_raw))
        _figure_site_profile(site_raw, site_general, wiki, profile, approved)
    records, seen, canonical_facts, observed_files = [], set(), {}, set()
    observing = False
    base_count = observed_count = 0
    for batch_index, batch in enumerate(batches):
        if (not isinstance(batch, dict) or set(batch) not in ({'requests', 'response'}, {'requests', 'response', 'observed_svg_width_px'}) or
                not isinstance(batch['response'], str) or not isinstance(batch['requests'], list) or
                not 1 <= len(batch['requests']) <= 50):
            raise ValueError('Invalid Figure source batch')
        observation = batch.get('observed_svg_width_px')
        if 'observed_svg_width_px' in batch:
            if type(observation) is not int or not 0 < observation < 2**32 or len(batch['requests']) != 1:
                raise ValueError('Invalid Figure observed-width batch')
            observing = True
            observed_count += 1
        elif observing:
            raise ValueError('Observed-width supplements must follow ordinary file batches')
        else:
            base_count += 1
        response_raw = batch['response'].encode('utf-8')
        if len(response_raw) > MAX_RESPONSE:
            raise ValueError('Figure API response exceeds per-response bound')
        titles = batch['requests']
        for title in titles:
            if (not isinstance(title, str) or registry.file_title(title) != title or
                    any(char in title for char in '\t\r\n\0') or
                    (title in seen if observation is None else title not in seen)):
                raise ValueError('Duplicate or noncanonical Figure source request')
            seen.add(title)
        if len(metadata.query_url(wiki, titles, figure_axes=True)) > metadata.MAX_URL:
            raise ValueError('Figure source batch exceeds URL bound')
        if record_limit is not None and len(seen) > record_limit:
            raise ValueError('Figure file inventory exceeds bounded capacity')
        data = decode(response_raw)
        require_edition(data, wiki)
        general = data['query']['general']
        if general.get('git-hash') != core or general.get('lang') != language:
            raise ValueError('Figure batches mix site/source versions')
        _figure_site_profile(site_raw, general, wiki, profile, approved)
        _figure_site_profile(response_raw, general, wiki,
                            dict(approved, site_raw_sha256=digest(response_raw)), approved)
        observed = data.get('curtimestamp')
        if not isinstance(observed, str) or not re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z', observed):
            raise ValueError('Missing same-response Figure observation time')
        observed_key = _figure_utc_key(observed)
        rows = metadata.classify_response(data, titles, registry)
        pages = {page['title']: page for page in data['query']['pages']}
        for title in titles:
            row = rows[title]
            record = {'requested_file': title, 'canonical_file': registry.file_title(row['response_title']), 'state': 'missing',
                      'batch': batch_index, 'file_sha1': '', 'file_timestamp': '',
                      'original_width': 0, 'original_height': 0, 'mime': '', 'mediatype': ''}
            if row['exists']:
                info = pages[row['response_title']]['imageinfo'][0]
                mime = info.get('mime')
                if not isinstance(mime, str) or not mime:
                    raise ValueError('Figure API omitted explicit MIME identity')
                if _figure_utc_key(row['file_timestamp']) > observed_key:
                    raise ValueError('File revision postdates its own response observation')
                family = approved['handler_families'].get(mime)
                if family is not None and row['mediatype'] != family['mediatype']:
                    raise ValueError('Source handler and MediaWiki type conflict')
                eligible = family is not None and row['width'] > 0 and row['height'] > 0
                if mime == 'image/tiff':
                    try:
                        _figure_tiff_page_axes(info, row['width'], row['height'])
                    except ValueError:
                        eligible = False
                record.update(canonical_file=registry.file_title(row['canonicaltitle']),
                    state='eligible' if eligible else 'unsupported', file_sha1=row['file_sha1'],
                    file_timestamp=row['file_timestamp'], original_width=row['width'],
                    original_height=row['height'], mime=mime, mediatype=row['mediatype'])
            facts = file_fact_identity(record)
            previous = canonical_facts.setdefault(record['canonical_file'], facts)
            if previous != facts:
                raise ValueError('Conflicting canonical file facts across Figure batches')
            if observation is not None:
                canonical = record['canonical_file']
                if (record['state'] != 'eligible' or canonical in observed_files or
                        observed_svg_width(info, record['mime'], record['mediatype'], record['original_width'], record['original_height']) != observation):
                    raise ValueError('Unproved or duplicate observed SVG width')
                observed_files.add(canonical)
                for base in records:
                    if base['canonical_file'] == canonical:
                        base['observed_svg_width_px'] = observation
                        base['observed_batch'] = batch_index
                continue
            records.append(record)
    for record in records:
        target = canonical_facts.get(record['requested_file'])
        facts = file_fact_identity(record)
        if target is not None and target != facts:
            raise ValueError('Requested file conflicts with an authenticated canonical alias')
    records.sort(key=lambda row: row['requested_file'].encode('utf-8'))
    return {'wiki': wiki, 'content_language': language, 'core_revision': core,
            'namespace_registry_sha256': digest(namespace_raw), 'source_profile': profile,
            'records': records, 'base_batches': base_count, 'observed_batches': observed_count}


def figure_file_document(raw, namespace_raw, wiki, date, site_raw):
    """Replay file facts; widths remain actual compiler occurrence arguments.

    This grants only requested_fit for eligible logical axes. Missing and
    unsupported source files remain explicit, and no occurrence completeness
    follows from a complete filename inventory.
    """
    if len(raw) > MAX_METADATA or len(namespace_raw) > MAX_METADATA or len(site_raw) > MAX_RESPONSE:
        raise ValueError('Figure file authority exceeds bounded capacity')
    envelope = decode(raw)
    if (not isinstance(envelope, dict) or set(envelope) != {'schema', 'batches'} or
            envelope['schema'] != RAW_BATCHES_SCHEMA or not isinstance(envelope['batches'], list) or
            len(envelope['batches']) > MAX_BATCHES):
        raise ValueError('Invalid Figure raw batch inventory')
    result = file_records(envelope['batches'], namespace_raw, wiki, date, site_raw,
                          has_batches=bool(envelope['batches']), record_limit=MAX_TITLES)
    del result['base_batches'], result['observed_batches']
    result.update(schema=FILES_SCHEMA, raw_sha256=digest(raw), generator_sha256=producer()['generator_sha256'])
    if len(encoded(result)) > MAX_METADATA:
        raise ValueError('Figure file projection exceeds bounded capacity')
    return result


def verify_figure_file_document(projection, raw, namespace_raw, wiki, date, site_raw):
    if (not isinstance(projection, dict) or not isinstance(projection.get('generator_sha256'), str) or
            re.fullmatch('[0-9a-f]{64}', projection['generator_sha256']) is None):
        raise ValueError('Invalid Figure file generator provenance')
    expected = figure_file_document(raw, namespace_raw, wiki, date, site_raw)
    expected['generator_sha256'] = projection['generator_sha256']
    if encoded(expected) != encoded(projection):
        raise ValueError('Figure file projection differs from exact batch replay')
    return projection


INVENTORY = 'figure-file-inventory.json'
INVENTORY_SCHEMA = 'wikidict.figure-file-inventory.v1'
FILE_REQUESTS = 'figure-file-requests.json'
PROVIDER = 'file-metadata.tsv'
QUERY_INPUTS = 'figure-file-query-inputs.json'


def provider_query_titles(root, inputs, namespace, wiki, date):
    """Observed probes supplement SQL names; neither implies Lua query closure."""
    if not isinstance(inputs, list) or len(inputs) > 1024:
        raise ValueError('Invalid observed file query inputs')
    registry = evidence.Registry(namespace, wiki, date)
    titles, seen = set(), set()
    total = 0
    for row in inputs:
        if (not isinstance(row, dict) or row.get('kind') != 'log' or
                not isinstance(row.get('path'), str) or
                re.fullmatch(r'figure-file-query-\d{4}\.log', row['path']) is None or
                row['path'] in seen):
            raise ValueError('Invalid or duplicate observed file query source')
        seen.add(row['path'])
        path = Path(root) / row['path']
        if evidence.stamp(path)[2] > MAX_METADATA - total:
            raise ValueError('Observed file query sources exceed bounded capacity')
        actual = evidence.fingerprint(path)
        total += actual['size']
        if total > MAX_METADATA or any(row.get(key) != value for key, value in actual.items()):
            raise ValueError('Observed file query source changed or exceeds bounds')
        with path.open('rb') as source:
            while raw := source.readline(evidence.MAX_LINE + 1):
                if len(raw) > evidence.MAX_LINE:
                    raise ValueError('Oversized seed line')
                match = re.search(r'file metadata (?:snapshot unavailable|missing): title=(.*)$',
                                  raw.decode('utf-8').rstrip('\r\n'))
                if match:
                    title = registry.file_title(match[1])
                    if registry.file_title(title) != title:
                        raise ValueError('Non-idempotent observed filename normalization')
                    titles.add(title)
    return titles


def provider_tsv(projection):
    # The caller has replayed every source batch through classify_response.
    # Figure-ineligible media (including audio) remains a positive Lua fact.
    records = {}
    for row in projection['records']:
        present = row['state'] != 'missing'
        records[row['requested_file']] = {
            'exists': present, 'width': row['original_width'], 'height': row['original_height'],
            'mediatype': row['mediatype'] if present else '-',
            'canonicaltitle': row['canonical_file'] if present else '-',
        }
    return metadata.render(records)


def provider_chunks(projection):
    header = (metadata.HEADER+'\n').encode()
    yield header
    for row in projection['records']:
        present = row['state'] != 'missing'
        rendered = metadata.render({row['requested_file']: {
            'exists': present, 'width': row['original_width'], 'height': row['original_height'],
            'mediatype': row['mediatype'] if present else '-',
            'canonicaltitle': row['canonical_file'] if present else '-',
        }})
        if not rendered.startswith(header):
            raise ValueError('Provider renderer header changed')
        yield rendered[len(header):]


def verify_provider_stream(path, projection):
    before = evidence.stamp(Path(path))
    with Path(path).open('rb') as source:
        for expected in provider_chunks(projection):
            if source.read(len(expected)) != expected:
                raise ValueError('Provider TSV differs from the authenticated file batches')
        if source.read(1):
            raise ValueError('Trailing Provider TSV data')
    if evidence.stamp(Path(path)) != before:
        raise ValueError('Provider TSV changed during replay')


def inventory_document(path):
    # This is the compact selected-name set, not a retained HTTP response DOM.
    before = evidence.stamp(Path(path))
    with Path(path).open('r', encoding='utf-8') as source:
        value = json.load(source, object_pairs_hook=evidence.unique_object,
                          parse_constant=lambda _: (_ for _ in ()).throw(ValueError('Nonfinite inventory number')))
    if evidence.stamp(Path(path)) != before:
        raise ValueError('Figure inventory changed during reading')
    return value


def output_roles(root):
    return {**ROLES, **({'file-metadata': PROVIDER} if (Path(root) / PROVIDER).exists() else {})}


def source_inventory(namespace_raw, wiki, date, dumpstatus_raw, paths):
    """Use the existing authenticated SQL seed parser, including emitted links."""
    registry = evidence.Registry(namespace_raw, wiki, date)
    expected_names = {f'{wiki}-{date}-{table}.sql.gz' for table in ('image', 'imagelinks')}
    target_name = f'{wiki}-{date}-linktarget.sql.gz'
    selected = [Path(path) for path in paths]
    selected_names = {path.name for path in selected}
    if (len(selected_names) != len(selected) or not expected_names <= selected_names or
            selected_names - expected_names - {target_name}):
        raise ValueError('Complete Figure file inventory requires dated image and imagelinks SQL')
    status = decode(dumpstatus_raw)
    if not isinstance(status, dict) or not isinstance(status.get('jobs'), dict):
        raise ValueError('Invalid dated Figure dumpstatus authority')
    titles, sources, stamps = set(), [], {}
    for path in sorted(selected):
        if path.is_symlink() or not path.is_file():
            raise ValueError('Unsafe Figure SQL input')
        stamps[path] = evidence.stamp(path)
        if stamps[path][2] > evidence.MAX_INPUT:
            raise ValueError('Figure SQL exceeds bounded preparation capacity')
        table = path.name.removeprefix(f'{wiki}-{date}-').removesuffix('.sql.gz')
        job = status['jobs'].get(table+'table')
        if not isinstance(job, dict) or not isinstance(job.get('files'), dict):
            raise ValueError('Missing dated Figure SQL job authority')
        expected = job['files'].get(path.name)
        if not isinstance(expected, dict):
            raise ValueError('Missing dated Figure SQL file authority')
        identity = evidence.fingerprint(path)
        url = f'/{wiki}/{date}/{path.name}'
        if (identity['size'] > evidence.MAX_INPUT or job.get('status') != 'done' or
                identity['size'] != expected.get('size') or identity['sha1'] != expected.get('sha1') or
                expected.get('url') != url):
            raise ValueError('Figure SQL differs from exact dated dumpstatus authority')
        sources.append({'path': str(path.resolve()), 'wiki': wiki, 'date': date, 'url': url,
                        'name': path.name, 'size': identity['size'], 'sha1': identity['sha1'],
                        'sha256': identity['sha256']})
    by_name = {path.name: path for path in selected}
    def add_name(name):
        if not isinstance(name, bytes):
            raise ValueError('Invalid Figure SQL filename')
        title = registry.file_title(registry.specs[6]['name']+':'+name.decode('utf-8'))
        if registry.file_title(title) != title:
            raise ValueError('Non-idempotent Figure filename normalization')
        titles.add(title)
    for name, in evidence.sql_rows(by_name[f'{wiki}-{date}-image.sql.gz'], ('img_name',)):
        add_name(name)
    links = by_name[f'{wiki}-{date}-imagelinks.sql.gz']
    with gzip.open(links, 'rb') as stream:
        header = stream.read(65536)
    schema = re.search(rb'CREATE TABLE `imagelinks` \((.*?)\n\)', header, re.S)
    if schema is None:
        raise ValueError('Missing bounded imagelinks schema')
    columns = re.findall(rb'^  `([^`]+)`', schema[1], re.M)
    if b'il_to' in columns and b'il_target_id' not in columns:
        if target_name in by_name:
            raise ValueError('Legacy imagelinks inventory does not consume linktarget')
        for name, in evidence.sql_rows(links, ('il_to',)):
            add_name(name)
        link_mode = 'il_to'
    elif b'il_target_id' in columns and b'il_to' not in columns:
        if target_name not in by_name:
            raise ValueError('This imagelinks schema requires the matching dated linktarget SQL')
        targets = set()
        for target, in evidence.sql_rows(links, ('il_target_id',)):
            if type(target) is not int or not 0 < target < 2**64:
                raise ValueError('Invalid imagelinks target identity')
            targets.add(target)
        resolved = set()
        # The global table includes unrelated namespaces. Stream its bounded
        # SQL lines, retaining only the selected imagelinks target set.
        # Keep reading after resolution so late duplicate targets still fail.
        for target, namespace, name in evidence.sql_rows(by_name[target_name], ('lt_id', 'lt_namespace', 'lt_title')):
            if type(target) is not int or not 0 < target < 2**64 or type(namespace) is not int:
                raise ValueError('Invalid linktarget identity')
            if target not in targets:
                continue
            if target in resolved or namespace != 6:
                raise ValueError('Conflicting or non-file imagelinks target')
            resolved.add(target)
            add_name(name)
        if resolved != targets:
            raise ValueError('Imagelinks target is absent from the dated linktarget table')
        link_mode = 'il_target_id-to-linktarget-namespace6'
    else:
        raise ValueError('Unsupported or ambiguous imagelinks filename schema')
    if any(evidence.stamp(path) != before for path, before in stamps.items()):
        raise ValueError('Figure SQL input changed during inventory replay')
    names = sorted(titles, key=lambda name: name.encode('utf-8'))
    return {'schema': INVENTORY_SCHEMA, 'wiki': wiki, 'date': date,
            'namespace_registry_sha256': digest(namespace_raw), 'sources': sources,
            'dumpstatus_raw': dumpstatus_raw.decode('utf-8'), 'dumpstatus_sha256': digest(dumpstatus_raw),
            'titles': names, 'imagelinks_mode': link_mode,
            'scope': 'dated-local-image-table-and-server-expanded-imagelinks',
            'temporal_scope': 'dump file-name inventory; API axes are separately observed current facts'}


def verify_inventory(value, namespace_raw, wiki, date):
    if (not isinstance(value, dict) or value.get('schema') != INVENTORY_SCHEMA or
            not isinstance(value.get('sources'), list) or not isinstance(value.get('dumpstatus_raw'), str)):
        raise ValueError('Invalid Figure inventory authority')
    paths = []
    for row in value['sources']:
        if not isinstance(row, dict) or not isinstance(row.get('path'), str) or not Path(row['path']).is_absolute():
            raise ValueError('Invalid Figure inventory source locator')
        paths.append(Path(row['path']))
    expected = source_inventory(namespace_raw, wiki, date, value['dumpstatus_raw'].encode(), paths)
    if encoded(expected) != encoded(value):
        raise ValueError('Figure file inventory differs from exact dated SQL replay')
    return value


def file_coverage(projection, inventory, query_titles=None):
    names = [row['requested_file'] for row in projection['records']]
    selected = set(inventory['titles']) | set(query_titles or ())
    if names != sorted(selected, key=lambda name: name.encode('utf-8')):
        raise ValueError('Figure batches do not cover the authenticated file inventory exactly')
    counts = {state: sum(row['state'] == state for row in projection['records'])
              for state in ('eligible', 'missing', 'unsupported')}
    result = {'kind': 'file-logical-axes', 'file_inventory_complete': True,
            'whole_edition_occurrence_coverage': False, 'files': len(names), **counts,
            'eligible_occurrences': 'thumbnail with actual positive width <= source logical width and no height',
            'unsupported_occurrences': ['width-above-original', 'height-bound', 'framed', 'intrinsic',
                                        'unobserved-default-or-upright', 'missing-or-unsupported-file'],
            'inventory_sha256': digest(encoded(inventory))}
    observed = sum('observed_svg_width_px' in row for row in projection['records'])
    if observed:
        result['observed_svg_files'] = observed
        result['eligible_occurrences'] += '; or the exact corroborated rasterized SVG width, without height'
        result['unsupported_occurrences'][0] = 'unobserved-width-above-original'
    if query_titles is not None:
        result['provider'] = {'header_version': 2, 'rows': len(names),
            'positive_rows': counts['eligible'] + counts['unsupported'], 'negative_rows': counts['missing'],
            'sql_files': len(inventory['titles']), 'observed_query_files': len(query_titles),
            'observed_only_files': len(set(query_titles) - set(inventory['titles'])),
            'corpus_query_closure_proven': False}
    return result


def payload(root):
    result = {}
    for path in sorted(Path(root).iterdir()):
        if path.name in (MANIFEST, COMPLETE):
            continue
        identity = evidence.fingerprint(path)
        result[path.name] = {'bytes': identity['size'], 'sha256': identity['sha256']}
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
    with (root / ROLES['figure-sizing']).open('rb') as source:
        first = source.readline(STREAM_HEADER_LIMIT + 1)
    try:
        stream_header = stream_decode(first) if len(first) <= STREAM_HEADER_LIMIT else None
    except (ValueError, UnicodeError):
        stream_header = None
    if isinstance(stream_header, dict) and stream_header.get('schema') == FILES_STREAM_SCHEMA:
        return replay_stream_capture(root, wiki, date, defaults, namespace, general)
    projection_raw = small(root / ROLES['figure-sizing'])
    projection = decode(projection_raw)
    file_level = isinstance(projection, dict) and projection.get('schema') == FILES_SCHEMA
    raw = small(root / ROLES['figure-sizing-raw'], MAX_METADATA if file_level else MAX_RESPONSE)
    site_raw = small(root / ROLES['figure-sizing-site'], MAX_RESPONSE)
    if file_level:
        if not figure_source_compatible(projection.get('core_revision'), general.get('git-hash')):
            raise ValueError('Figure defaults and file facts use different source versions')
        verify_figure_file_document(projection, raw, namespace, wiki, date, site_raw)
        inventory = verify_inventory(decode(small(root / INVENTORY)), namespace, wiki, date)
        shared = (root / PROVIDER).exists() or (root / QUERY_INPUTS).exists()
        query_inputs = decode(small(root / QUERY_INPUTS)) if shared else []
        query_titles = provider_query_titles(root, query_inputs, namespace, wiki, date) if shared else None
        coverage = file_coverage(projection, inventory, query_titles)
        if shared and small(root / PROVIDER) != provider_tsv(projection):
            raise ValueError('Provider TSV differs from the same authenticated file batches')
        sources = decode(small(root / FILE_REQUESTS))
        expected_batches, http_files = replay_file_requests(root, sources, wiki, date)
        if encoded({'schema': RAW_BATCHES_SCHEMA, 'batches': expected_batches}) != raw:
            raise ValueError('Figure raw batches differ from their preserved capture sources')
        expected_files = {*defaults['artifacts'], site_info.MANIFEST, site_info.COMPLETE,
                          *ROLES.values(), INVENTORY, FILE_REQUESTS, *http_files}
        if shared:
            expected_files.update((PROVIDER, QUERY_INPUTS, *(row['path'] for row in query_inputs)))
        if set(payload(root)) != expected_files:
            raise ValueError('Unexpected or incomplete Figure file evidence inventory')
        return defaults, coverage
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
    if coverage['kind'] == 'file-logical-axes':
        inventory = inventory_document(root / INVENTORY)
        expected_sources = [{key: row[key] for key in ('wiki', 'date', 'name', 'url', 'size', 'sha1')}
                            for row in inventory['sources']]
        if manifest.get('capture_format') == FILES_STREAM_SCHEMA:
            for row in expected_sources:
                row['url'] = 'https://dumps.wikimedia.org'+row['url']
        if manifest.get('source_dump_files') != expected_sources:
            raise ValueError('Figure file source selection differs from the verified inventory')
    if (manifest.get('namespace_registry_sha256') != defaults['namespace_registry_sha256'] or
            manifest.get('coverage') != coverage or manifest.get('artifacts') != payload(root) or
            manifest.get('outputs') != {name: evidence.fingerprint(root / filename)['sha256'] for name, filename in output_roles(root).items()}):
        raise ValueError('Figure capture differs from source replay')
    return manifest


def validate_snapshot(path, wiki=None, date=None):
    path = Path(path)
    if path.name not in (*ROLES.values(), PROVIDER):
        raise ValueError('Unexpected Figure snapshot filename')
    manifest = verify(path.parent)
    if (wiki is not None and manifest['wiki'] != wiki) or (date is not None and manifest['date'] != date):
        raise ValueError('Figure capture edition/date mismatch')
    role = next(name for name, filename in output_roles(path.parent).items() if filename == path.name)
    return {**manifest, 'output_sha256': manifest['outputs'][role]}


def verify_tuple(paths, wiki=None, date=None):
    """One semantic replay for one invocation-local, complete source tuple."""
    if set(paths) not in (set(ROLES), {*ROLES, 'file-metadata'}):
        raise ValueError('Incomplete Figure source tuple')
    selected_roles = {**ROLES, 'file-metadata': PROVIDER}
    parents = set()
    for role, path in paths.items():
        path = Path(path)
        if path.name != selected_roles[role] or path.is_symlink():
            raise ValueError('Unexpected Figure role path')
        parents.add(path.parent)
    if len(parents) != 1:
        raise ValueError('Figure input roles belong to different source captures')
    root = parents.pop()
    manifest_raw = small(root / MANIFEST)
    manifest = verify(root)
    if set(paths) != set(manifest['outputs']):
        raise ValueError('Shared file capture requires its Provider TSV and all four Figure roles')
    if (wiki is not None and manifest['wiki'] != wiki) or (date is not None and manifest['date'] != date):
        raise ValueError('Figure capture edition/date mismatch')
    # Recheck every immutable source byte after the semantic replay. The local
    # result is shared only by this selected tuple at this boundary.
    marker_raw = encoded({'schema': SCHEMA, 'manifest_sha256': digest(manifest_raw)})
    if (small(root / MANIFEST) != manifest_raw or decode(manifest_raw) != manifest or
            payload(root) != manifest['artifacts'] or small(root / COMPLETE) != marker_raw):
        raise ValueError('Figure source capture changed during validation')
    inventory = {**{name: row['sha256'] for name, row in manifest['artifacts'].items()},
                 MANIFEST: digest(manifest_raw), COMPLETE: digest(marker_raw)}
    return {role: ({**manifest, 'output_sha256': manifest['outputs'][role]}, dict(inventory))
            for role in paths}


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


def retained_file_batch(root, wiki, date):
    """Reuse a whole verified occurrence response without dropping its pages."""
    root = Path(root)
    declared = decode(small(root / MANIFEST))
    if (not isinstance(declared, dict) or not isinstance(declared.get('coverage'), dict) or
            declared['coverage'].get('kind') != 'selected-occurrences'):
        raise ValueError('Reuse requires a retained occurrence capture')
    manifest = verify(root)
    if manifest['wiki'] != wiki or manifest['date'] != date or manifest['coverage']['kind'] != 'selected-occurrences':
        raise ValueError('Reuse requires a matching retained occurrence capture')
    requests = decode(small(root / REQUESTS))
    titles = sorted({row['canonical_file'] for row in requests}, key=lambda value: value.encode())
    raw = small(root / ROLES['figure-sizing-raw'], MAX_RESPONSE)
    # The existing v1 verifier has already checked every requested tuple and
    # every raw page. The new file verifier independently replays logical axes.
    return {'requests': titles, 'response': raw.decode('utf-8')}


def observed_artifact_name(name):
    if not isinstance(name, str) or re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', name) is None:
        raise ValueError('Unsafe observed Figure artifact name')
    return name


def retained_svg_observation(root, record, wiki, date, namespace):
    """Replay a distinct, already captured width request through --reuse-batch.

    This is not a fixed figure_axes request. Its unchanged request, accepted
    receipt and raw response are pinned by the enclosing retained batch record.
    """
    width = record['observed_svg_width_px']
    batch = record.get('batch')
    if (type(width) is not int or not 0 < width < 2**32 or
            not isinstance(batch, dict) or set(batch) != {'request', 'accepted_receipt'}):
        raise ValueError('Invalid observed SVG request scope')
    for name in batch.values():
        if observed_artifact_name(name) not in record['artifacts']:
            raise ValueError('Unrecorded observed SVG request or receipt')
    request = decode(small(root / batch['request']))
    names = request.get('titles') if isinstance(request, dict) else None
    registry = evidence.Registry(namespace, wiki, date)
    if (not isinstance(names, list) or len(names) != 1 or not isinstance(names[0], str) or
            registry.file_title(names[0]) != names[0]):
        raise ValueError('Observed SVG request must name one canonical file')
    query = {'action': 'query', 'format': 'json', 'formatversion': '2',
             'meta': 'siteinfo', 'siprop': 'general|extensions', 'prop': 'imageinfo',
             'iiprop': 'size|sha1|timestamp|canonicaltitle|mediatype|mime|metadata|url',
             'iilimit': '1', 'redirects': '1', 'maxlag': '5', 'titles': names[0],
             'curtimestamp': '1', 'iiurlwidth': str(width)}
    url = request.get('url')
    if (request.get('fixed_verified_batch_contract') is not False or
            type(request.get('request_count')) is not int or request['request_count'] != 1 or
            request.get('query') != query or not isinstance(url, str) or len(url) > metadata.MAX_URL):
        raise ValueError('Observed SVG query semantics changed')
    parsed = urlsplit(url)
    if (parsed.fragment or parsed._replace(query='', fragment='').geturl() != wiktionary_api(wiki) or
            sorted(parse_qsl(parsed.query, keep_blank_values=True)) != sorted(query.items())):
        raise ValueError('Observed SVG endpoint or query changed')
    receipt = decode(small(root / batch['accepted_receipt']))
    if (not isinstance(receipt, dict) or receipt.get('accepted') is not True or
            type(receipt.get('status')) is not int or receipt['status'] != 200 or
            type(receipt.get('request_count')) is not int or receipt['request_count'] != 1 or
            observed_artifact_name(receipt.get('response')) not in record['artifacts']):
        raise ValueError('Invalid observed SVG accepted receipt')
    raw = small(root / receipt['response'], MAX_RESPONSE)
    if receipt.get('response_bytes') != len(raw) or receipt.get('response_sha256') != digest(raw):
        raise ValueError('Observed SVG response changed')
    data = decode(raw)
    require_edition(data, wiki)
    rows = metadata.classify_response(data, names, registry)
    row = rows[names[0]]
    pages = {page['title']: page for page in data['query']['pages']}
    if not row['exists']:
        raise ValueError('Observed SVG file is not positive')
    info = pages[row['response_title']]['imageinfo'][0]
    if observed_svg_width(info, info.get('mime'), row['mediatype'], row['width'], row['height']) != width:
        raise ValueError('Observed SVG request lacks exact rasterized width proof')
    return {'requests': names, 'response': raw.decode('utf-8'), 'observed_svg_width_px': width}


def retained_metadata_batch(path, wiki, date, namespace):
    """Reuse an existing request/receipt record; rederive facts from its raw API bytes."""
    path = Path(path)
    record = decode(small(path))
    if (path.parent.is_symlink() or not isinstance(record, dict) or
            record.get('wiki') != wiki or record.get('date') != date or
            not isinstance(record.get('artifacts'), dict) or not 4 <= len(record['artifacts']) <= 10):
        raise ValueError('Invalid retained file batch evidence')
    for name, expected in record['artifacts'].items():
        (observed_artifact_name if 'observed_svg_width_px' in record else metadata.safe_name)(name)
        if not isinstance(expected, dict) or set(expected) != {'size', 'sha256'}:
            raise ValueError('Invalid retained file artifact identity')
        data = small(path.parent / name, MAX_RESPONSE)
        if expected != {'size': len(data), 'sha256': digest(data)}:
            raise ValueError('Retained file batch artifact changed')
    if (metadata.NAMESPACE not in record['artifacts'] or
            small(path.parent / metadata.NAMESPACE) != namespace):
        raise ValueError('Retained file batch uses a different namespace')
    if 'observed_svg_width_px' in record:
        return retained_svg_observation(path.parent, record, wiki, date, namespace)
    names, response = metadata.verified_batch(path.parent, record.get('batch'), wiki,
                                              record['artifacts'], figure_axes=True)
    return {'requests': names, 'response': response.decode('utf-8')}


def replay_file_requests(root, sources, wiki, date):
    if not isinstance(sources, list) or len(sources) > MAX_BATCHES:
        raise ValueError('Invalid Figure file request inventory')
    batches, http_files = [], set()
    artifacts = payload(root)
    for source in sources:
        if not isinstance(source, dict):
            raise ValueError('Invalid Figure file request source')
        if source.get('kind') == 'retained-occurrences' and set(source) == {'kind', 'path', 'manifest_sha256'}:
            if not isinstance(source['path'], str) or not isinstance(source['manifest_sha256'], str):
                raise ValueError('Invalid retained Figure source locator')
            path = Path(source['path'])
            if (not path.is_absolute() or path.resolve() == root.resolve() or
                    digest(small(path / MANIFEST)) != source['manifest_sha256']):
                raise ValueError('Retained Figure source changed or aliases output')
            batches.append(retained_file_batch(path, wiki, date))
        elif source.get('kind') == 'retained-request' and set(source) == {'kind', 'path', 'sha256'}:
            if not isinstance(source['path'], str) or not isinstance(source['sha256'], str):
                raise ValueError('Invalid retained file batch locator')
            path = Path(source['path'])
            if (not path.is_absolute() or path.parent.resolve() == root.resolve() or
                    digest(small(path)) != source['sha256']):
                raise ValueError('Retained file batch record changed or aliases output')
            namespace = small(root / (site_info.PREFIX + 'namespace-registry.tsv'))
            batches.append(retained_metadata_batch(path, wiki, date, namespace))
        elif source.get('kind') == 'http' and set(source) == {'kind', 'batch', 'artifacts'}:
            names = source['artifacts']
            if (not isinstance(names, list) or not names or
                    any(not isinstance(name, str) for name in names) or len(set(names)) != len(names)):
                raise ValueError('Invalid Figure HTTP evidence list')
            for name in names:
                metadata.safe_name(name)
                if name not in artifacts or name in http_files:
                    raise ValueError('Missing or duplicate Figure HTTP artifact')
                http_files.add(name)
            titles, response = metadata.verified_batch(root, source['batch'], wiki,
                                                       set(names), figure_axes=True)
            batches.append({'requests': titles, 'response': response.decode('utf-8')})
        else:
            raise ValueError('Unknown Figure request source')
    return batches, http_files


REQUEST_STREAM_SCHEMA = 'wikidict.figure-file-requests.stream.v1'
PLAN = 'figure-capture-plan.json'
RESUME = 'figure-resume.json'
WALL_ERRORS = ('Original capture wall deadline reached', 'Capture wall deadline reached',
               'Retry exceeds bounded capture wait/deadline')


def capture_source():
    return {**producer(), 'dependency_sha256': {**metadata.producer()['dependency_sha256'], **{
        module.__name__: evidence.fingerprint(Path(module.__file__))['sha256']
        for module in (evidence, metadata, site_info)}}}


def source_records(path, expected):
    before = evidence.stamp(Path(path))
    with Path(path).open('rb') as stream:
        line = stream.readline(STREAM_HEADER_LIMIT + 1)
        if len(line) > STREAM_HEADER_LIMIT:
            raise ValueError('Figure request header exceeds its bound')
        header = stream_decode(line)
        if header != {'schema': REQUEST_STREAM_SCHEMA, 'batches': expected}:
            raise ValueError('Figure request stream header differs')
        for _ in range(expected):
            line = stream.readline(STREAM_HEADER_LIMIT + 1)
            if len(line) > STREAM_HEADER_LIMIT:
                raise ValueError('Figure request record exceeds its bound')
            yield stream_decode(line)
        if stream.read(1):
            raise ValueError('Trailing Figure request records')
    if evidence.stamp(Path(path)) != before:
        raise ValueError('Figure requests changed during replay')


def replay_source(root, source, batch, wiki, date, namespace, http_files, prefix_cache=None):
    if not isinstance(source, dict):
        raise ValueError('Invalid Figure request source')
    kind = source.get('kind')
    if kind == 'closed-prefix':
        prefix = read_closed_prefix(Path(source['path']), prefix_cache)
        if (prefix['record']['wiki'] != wiki or prefix['record']['date'] != date or
                prefix['namespace'] != namespace or closed_prefix_batch(source, prefix_cache) != batch):
            raise ValueError('Retained closed Figure batch identity differs')
        return
    if kind in ('retained-occurrences', 'retained-request'):
        expected_keys = {'kind', 'path', 'manifest_sha256' if kind == 'retained-occurrences' else 'sha256'}
        if set(source) != expected_keys or not isinstance(source['path'], str):
            raise ValueError('Invalid retained Figure source')
        path = Path(source['path'])
        if not path.is_absolute() or path.resolve().is_relative_to(root.resolve()):
            raise ValueError('Retained Figure source aliases output')
        if kind == 'retained-occurrences':
            if digest(small(path / MANIFEST)) != source['manifest_sha256']:
                raise ValueError('Retained Figure manifest changed')
            expected = retained_file_batch(path, wiki, date)
        else:
            if digest(small(path)) != source['sha256']:
                raise ValueError('Retained Figure request changed')
            expected = retained_metadata_batch(path, wiki, date, namespace)
        if expected != batch:
            raise ValueError('Figure batch differs from its retained authority')
        return
    light = kind == 'http-archived-light'
    if kind not in ('http-archived', 'http-archived-light') or set(source) != {'kind', 'batch', 'artifacts'}:
        raise ValueError('Invalid archived Figure HTTP source')
    names, reference = source['artifacts'], source['batch']
    if (not isinstance(names, list) or any(not isinstance(name, str) for name in names) or
            len(names) != len(set(names)) or not isinstance(reference, dict) or
            set(reference) != {'request', 'accepted_receipt'} or
            any(not isinstance(name, str) for name in reference.values())):
        raise ValueError('Invalid archived HTTP inventory')
    for name in names:
        metadata.safe_name(name)
        if name in http_files:
            raise ValueError('Duplicate HTTP evidence')
        evidence.stamp(root / name)
        http_files.add(name)
    if not set(reference.values()) <= set(names):
        raise ValueError('Missing archived request or receipt')
    request = decode(small(root / reference['request']))
    titles = request.get('titles') if isinstance(request, dict) else None
    if (not isinstance(titles, list) or not 1 <= len(titles) <= 50 or
            any(not isinstance(title, str) for title in titles) or len(set(titles)) != len(titles)):
        raise ValueError('Invalid archived requested titles')
    if request != {'titles': titles, 'query': metadata.query_for(wiki, titles, figure_axes=True, figure_metadata_light=light),
                   'url': metadata.query_url(wiki, titles, figure_axes=True, figure_metadata_light=light)}:
        raise ValueError('Archived Figure request semantics changed')
    if len(request['url'].encode()) > metadata.MAX_URL:
        raise ValueError('Archived Figure URL exceeds its bound')
    receipt = decode(small(root / reference['accepted_receipt']))
    if not isinstance(receipt, dict):
        raise ValueError('Invalid archived HTTP receipt')
    match = re.fullmatch(r'file-metadata\.response-(\d{6})-(\d{2})\.receipt\.json', reference['accepted_receipt'])
    if match is None or not 1 <= int(match[2]) <= 4 or reference['request'] != f'file-metadata.request-{match[1]}.json':
        raise ValueError('Invalid archived HTTP request numbering')
    allowed = {reference['request']}
    for attempt in range(1, int(match[2])+1):
        stem = f'file-metadata.response-{match[1]}-{attempt:02d}'
        allowed.add(stem+'.receipt.json')
        failed_raw = root / (stem+'.raw.json')
        if attempt < int(match[2]) and failed_raw.exists():
            allowed.add(failed_raw.name)
    if set(names) != allowed:
        raise ValueError('Archived HTTP evidence has unrelated or incomplete files')
    response_name = metadata.safe_name(receipt.get('response'))
    if not isinstance(batch.get('response'), str):
        raise ValueError('Invalid archived response bytes')
    response = batch['response'].encode('utf-8')
    if (set(batch) != {'requests', 'response'} or batch['requests'] != titles or
            len(response) > MAX_RESPONSE or receipt.get('accepted') is not True or
            receipt.get('status') != 200 or receipt.get('request') != reference['request'] or
            receipt.get('response_bytes') != len(response) or receipt.get('response_sha256') != digest(response)):
        raise ValueError('Archived HTTP response differs from its accepted receipt')
    # A crash before retirement can leave the accepted duplicate. It is never
    # silently ignored or removed by verification.
    if (root / response_name).exists():
        raise ValueError('Unretired duplicate accepted response')
    if light:
        validate_metadata_light(batch, namespace, wiki, date)


def replay_stream_capture(root, wiki, date, defaults, namespace, general):
    site_raw = small(root / ROLES['figure-sizing-site'], MAX_RESPONSE)
    projection = verify_stream_document(root / ROLES['figure-sizing'], root / ROLES['figure-sizing-raw'],
                                        namespace, wiki, date, site_raw)
    if not figure_source_compatible(projection['core_revision'], general.get('git-hash')):
        raise ValueError('Figure defaults and streamed facts use different source versions')
    inventory = verify_inventory(inventory_document(root / INVENTORY), namespace, wiki, date)
    query_inputs = decode(small(root / QUERY_INPUTS))
    query_titles = provider_query_titles(root, query_inputs, namespace, wiki, date)
    coverage = file_coverage(projection, inventory, query_titles)
    verify_provider_stream(root / PROVIDER, projection)
    batches = stream_values(root / ROLES['figure-sizing-raw'], RAW_STREAM_SCHEMA)
    header = next(batches)
    sources = source_records(root / FILE_REQUESTS, header['base_batches']+header['observed_batches'])
    http_files, prefix_cache = set(), {}
    prefix_sources, light_requests, ordinary_requests = [], set(), set()
    for batch, source in zip(batches, sources, strict=True):
        replay_source(root, source, batch, wiki, date, namespace, http_files, prefix_cache)
        if source['kind'] == 'closed-prefix':
            prefix_sources.append(source)
        elif source['kind'] == 'http-archived-light':
            light_requests.update(batch['requests'])
        elif source['kind'] == 'http-archived':
            ordinary_requests.update(batch['requests'])
    check_prefix_cache(prefix_cache)
    plan = inventory_document(root / PLAN)
    if (plan.get('wiki') != wiki or plan.get('date') != date or
            plan.get('inventory_sha256') != digest(encoded(inventory)) or
            plan.get('namespace_registry_sha256') != digest(namespace) or
            plan.get('records_count') != header['records_count']):
        raise ValueError('Figure stream differs from its selected capture plan')
    prefixes = plan.get('closed_prefixes', [])
    if not isinstance(prefixes, list) or len(prefixes) > 1:
        raise ValueError('Invalid closed Figure transition selection')
    required_sources, required_light = [], set()
    for reference in prefixes:
        if (not isinstance(reference, dict) or set(reference) != {'kind', 'path', 'sha256'} or
                reference['kind'] != 'closed-prefix' or digest(small(Path(reference['path']))) != reference['sha256']):
            raise ValueError('Closed Figure transition authority changed')
        prefix = read_closed_prefix(Path(reference['path']), prefix_cache)
        required_sources.extend(dict(reference, batch=i) for i in range(len(prefix['offsets'])))
        required_light.update(prefix['light_titles'])
    if (prefix_sources != required_sources or light_requests != required_light or
            required_light & ordinary_requests or
            plan.get('metadata_light_titles', []) != sorted(required_light, key=lambda t:t.encode())):
        raise ValueError('Archived metadata-light scope differs from its closed transition')
    expected = {*defaults['artifacts'], site_info.MANIFEST, site_info.COMPLETE, *ROLES.values(),
                INVENTORY, FILE_REQUESTS, QUERY_INPUTS, PROVIDER, PLAN, *http_files,
                *(row['path'] for row in query_inputs)}
    manifest = decode(small(root / MANIFEST))
    if manifest.get('capture_format') != FILES_STREAM_SCHEMA:
        raise ValueError('Figure stream manifest format differs')
    resumes = manifest.get('resumes', [])
    if not isinstance(resumes, list) or any(not isinstance(row, dict) for row in resumes) or len({row.get('path') for row in resumes}) != len(resumes):
        raise ValueError('Invalid Figure resume history')
    for reference in resumes:
        proof = read_resume(root, reference, plan, live=False)
        expected.update((reference['path'], proof['failure']['path']))
    if set(payload(root)) != expected:
        raise ValueError('Unexpected or incomplete streamed Figure evidence')
    return defaults, coverage


def prefix_identity(path, size):
    before = evidence.stamp(Path(path))
    if type(size) is not int or not 0 <= size <= before[2]:
        raise ValueError('Invalid Figure checkpoint prefix size')
    sha = hashlib.sha256()
    with Path(path).open('rb') as source:
        remaining = size
        while remaining:
            raw = source.read(min(1024*1024, remaining))
            if not raw:
                raise ValueError('Truncated Figure checkpoint prefix')
            sha.update(raw)
            remaining -= len(raw)
    if evidence.stamp(Path(path)) != before:
        raise ValueError('Figure checkpoint changed while hashing')
    return {'bytes': size, 'sha256': sha.hexdigest()}


def append_prefix(path, expected_size):
    before = evidence.stamp(path)
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_NOFOLLOW)
    try:
        info = os.fstat(fd)
        if (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or
                (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns) != before or
                info.st_size != expected_size):
            raise ValueError('Figure prefix changed or is shared before append')
        output = os.fdopen(fd, 'ab')
        fd = None
        return output
    finally:
        if fd is not None:
            os.close(fd)


def read_resume(root, reference, plan, *, live):
    if (not isinstance(reference, dict) or set(reference) != {'path', 'bytes', 'sha256'} or
            re.fullmatch(r'figure-resume(?:-\d{4})?\.json', reference.get('path', '')) is None):
        raise ValueError('Invalid Figure resume reference')
    proof_raw = metadata.checkpoint_read(root / reference['path'], reference)
    proof = decode(proof_raw)
    if (not isinstance(proof, dict) or proof.get('schema') != 'wikidict.figure-closed-wall-stop.v1' or
            not isinstance(proof.get('source_root'), str) or not Path(proof['source_root']).is_absolute() or
            (live and proof['source_root'] != str(root.resolve())) or
            proof.get('plan_sha256') != digest(encoded(plan))):
        raise ValueError('Figure resume plan or source differs')
    failure_ref = proof.get('failure', {})
    if (not isinstance(failure_ref, dict) or
            re.fullmatch(r'figure-failure-\d{4}\.json', failure_ref.get('path', '')) is None):
        raise ValueError('Invalid Figure failure reference')
    failure_raw = metadata.checkpoint_read(root / failure_ref['path'], failure_ref)
    failure = decode(failure_raw)
    closure_raw = proof.get('closure_raw')
    if not isinstance(closure_raw, str) or proof.get('closure') != {
            'bytes': len(closure_raw.encode()), 'sha256': digest(closure_raw.encode())}:
        raise ValueError('Figure physical closure receipt differs')
    closure = decode(closure_raw)
    if (closure.get('outcome') != 'FAILED-PHYSICALLY-SOURCE-CLOSED' or
            any(closure.get(key) is not True for key in ('source_after', 'reaped', 'dual_proc_absence',
                                                        'ps_absence', 'allocation_released')) or
            type(closure.get('terminal')) is not int or closure['terminal'] == 0 or
            closure.get('capture_failure') != failure_ref or
            closure.get('capture_root') != proof['source_root'] or
            closure.get('capture_plan_sha256') != proof['plan_sha256']):
        raise ValueError('Figure resume lacks exact failed physical/source closure')
    if (failure.get('error') not in WALL_ERRORS or failure.get('source') != plan['source'] or
            failure.get('plan_sha256') != proof['plan_sha256'] or
            type(failure.get('committed_batches')) is not int or
            not 0 < failure['committed_batches'] < plan['base_batches']+plan['observed_batches']):
        raise ValueError('Figure checkpoint is not a nonempty closed wall-stop prefix')
    if live and capture_source() != plan['source']:
        raise ValueError('Figure continuation source changed')
    files = failure.get('artifacts')
    if not isinstance(files, dict):
        raise ValueError('Missing Figure prefix inventory')
    append_names = {ROLES['figure-sizing-raw'], FILE_REQUESTS}
    for name, descriptor in files.items():
        if not isinstance(name, str) or re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', name) is None:
            raise ValueError('Unsafe Figure checkpoint artifact name')
        if not isinstance(descriptor, dict) or set(descriptor) != {'bytes', 'sha256'}:
            raise ValueError('Invalid Figure prefix descriptor')
        if name in append_names:
            if prefix_identity(root / name, descriptor['bytes']) != descriptor:
                raise ValueError('Figure accepted prefix bytes changed')
            if live and evidence.stamp(root / name)[2] != descriptor['bytes']:
                raise ValueError('Uncommitted Figure prefix bytes')
        elif evidence.fingerprint(root / name)['sha256'] != descriptor['sha256'] or evidence.stamp(root / name)[2] != descriptor['bytes']:
            raise ValueError('Figure checkpoint evidence changed')
        if name.endswith('.receipt.json') and name.startswith('file-metadata.response-'):
            receipt = decode(small(root / name))
            if receipt.get('accepted') is not True and (receipt.get('status') is not None or receipt.get('api_error_code') is not None):
                raise ValueError('Rejected API observation requires separate scope review')
    if live and set(payload(root)) != {*files, failure_ref['path'], reference['path']}:
        raise ValueError('Figure checkpoint has uncommitted artifacts')
    proof['_failure'] = failure
    return proof


CLOSED_PREFIX_SCHEMA = 'wikidict.figure-closed-oversize-prefix.v1'


def validate_metadata_light(batch, namespace, wiki, date):
    """Omitted metadata can never authorize a supported image handler."""
    result = file_records((batch,), namespace, wiki, date, batch['response'].encode(),
                          has_batches=True, record_limit=50)
    families = result['source_profile']['handler_families']
    for row in result['records']:
        if row['state'] != 'missing' and (row['state'] != 'unsupported' or
                row['mime'] in families or row['mime'] == 'image/tiff'):
            raise ValueError('Metadata-light response requires explicit unsupported non-TIFF media')
    return result


def read_closed_prefix(path, cache=None):
    """Replay a closed oversize failure once per verification boundary.

    The original failed generation remains read-only. Only accepted lines are
    indexed; the truncated response is authenticated evidence, never file facts.
    """
    path = Path(path)
    raw = small(path)
    key = (str(path), digest(raw))
    if cache is not None and key in cache:
        result = cache[key]
        if any(evidence.stamp(p) != result['stamps'][p] for p in (path, result['raw_path'])):
            raise ValueError('Closed Figure prefix changed after authentication')
        return result
    record = decode(raw)
    if (not isinstance(record, dict) or set(record) != {
            'schema', 'wiki', 'date', 'source_root', 'original_root', 'closure', 'light_titles'} or
            record['schema'] != CLOSED_PREFIX_SCHEMA):
        raise ValueError('Invalid closed Figure prefix record')
    wiki, date = record['wiki'], record['date']
    wiktionary_api(wiki)
    if not isinstance(date, str) or re.fullmatch(r'\d{8}', date) is None:
        raise ValueError('Invalid closed Figure prefix edition/date')
    root, original = Path(record['source_root']), Path(record['original_root'])
    if any(not p.is_absolute() or p.resolve() != p or p.is_symlink() for p in (root, original, path)):
        raise ValueError('Unsafe closed Figure prefix locator')
    if (root / COMPLETE).exists() or (root / MANIFEST).exists():
        raise ValueError('A closed failed Figure prefix cannot be a published capture')
    closure_ref = record['closure']
    if not isinstance(closure_ref, dict) or set(closure_ref) != {'path', 'bytes', 'sha256'}:
        raise ValueError('Invalid closed Figure closure descriptor')
    closure_path = Path(closure_ref['path'])
    if not closure_path.is_absolute() or closure_path.resolve() != closure_path:
        raise ValueError('Unsafe Figure closure locator')
    closure = decode(metadata.checkpoint_read(closure_path, closure_ref))
    if (closure.get('outcome') != 'FAILED-PHYSICALLY-SOURCE-CLOSED' or
            any(closure.get(k) is not True for k in
                ('source_after', 'reaped', 'dual_proc_absence', 'ps_absence', 'allocation_released')) or
            type(closure.get('terminal')) is not int or closure['terminal'] == 0 or
            closure.get('capture_root') != str(original)):
        raise ValueError('Figure prefix lacks physical and source closure')
    stamps = {path: evidence.stamp(path), closure_path: evidence.stamp(closure_path)}
    identities = {}

    def bound(name):
        ref = closure.get(name)
        if not isinstance(ref, dict) or set(ref) != {'path', 'bytes', 'sha256'}:
            raise ValueError('Missing closed Figure evidence descriptor')
        old = Path(ref['path'])
        if old.parent != original:
            raise ValueError('Closed Figure evidence escaped its original generation')
        local = root / observed_artifact_name(old.name)
        before = evidence.stamp(local)
        identity = identities.get(local)
        if identity is None:
            identity = prefix_identity(local, before[2])
        if identity != {'bytes': ref['bytes'], 'sha256': ref['sha256']} or (local in stamps and stamps[local] != before):
            raise ValueError('Closed Figure evidence changed')
        stamps[local] = before
        identities[local] = identity
        return local

    failure_path = bound('capture_failure')
    failure = inventory_document(failure_path)
    plan_path = root / PLAN
    plan = inventory_document(plan_path)
    stamps[plan_path] = evidence.stamp(plan_path)
    if (plan.get('wiki') != wiki or plan.get('date') != date or
            closure.get('capture_plan_sha256') != digest(encoded(plan)) or
            failure.get('plan_sha256') != closure['capture_plan_sha256'] or
            failure.get('source') != plan.get('source') or
            failure.get('error') != 'Oversized API response' or
            failure.get('resumes') != [] or plan.get('observed_batches') != 0):
        raise ValueError('Figure transition is not the selected closed oversize failure')
    committed = failure.get('committed_batches')
    if (type(committed) is not int or not 0 < committed < plan.get('base_batches', 0) or
            closure.get('committed_batches') != committed):
        raise ValueError('Invalid closed Figure prefix count')
    files = failure.get('artifacts')
    if not isinstance(files, dict):
        raise ValueError('Missing closed Figure artifact inventory')
    for name, descriptor in files.items():
        observed_artifact_name(name)
        if not isinstance(descriptor, dict) or set(descriptor) != {'bytes', 'sha256'}:
            raise ValueError('Invalid closed Figure artifact identity')
        local = root / name
        before = evidence.stamp(local)
        if prefix_identity(local, before[2]) != descriptor:
            raise ValueError('Closed Figure artifact changed')
        stamps[local] = before
        identities[local] = descriptor
    if set(payload(root)) != {*files, failure_path.name}:
        raise ValueError('Closed Figure generation has unaccounted artifacts')
    request_path, receipt_path, rejected_path = (bound(name) for name in
        ('actual_request', 'actual_receipt', 'actual_response'))
    request, receipt = decode(small(request_path)), decode(small(receipt_path))
    titles = request.get('titles')
    if (not isinstance(titles, list) or not 1 <= len(titles) <= 50 or
            any(not isinstance(t, str) for t in titles) or len(set(titles)) != len(titles) or
            request != {'titles': titles, 'query': metadata.query_for(wiki, titles, figure_axes=True),
                        'url': metadata.query_url(wiki, titles, figure_axes=True)} or
            receipt.get('request') != request_path.name or receipt.get('response') != rejected_path.name or
            receipt.get('status') != 200 or receipt.get('accepted') is not False or
            receipt.get('api_error_code') is not None or receipt.get('error') != 'Oversized API response' or
            receipt.get('response_bytes') != MAX_RESPONSE + 1 or
            receipt.get('response_sha256') != closure['actual_response']['sha256'] or
            closure['actual_response']['bytes'] != MAX_RESPONSE + 1):
        raise ValueError('Figure transition requires exact oversized HTTP 200 evidence')
    light = record['light_titles']
    if (not isinstance(light, list) or not light or any(not isinstance(t, str) for t in light) or
            len(set(light)) != len(light) or not set(light) <= set(titles)):
        raise ValueError('Metadata-light selection differs from the failed request')
    namespace = small(root / (site_info.PREFIX + 'namespace-registry.tsv'))
    if digest(namespace) != plan['namespace_registry_sha256']:
        raise ValueError('Closed Figure namespace changed')
    inventory = inventory_document(root / INVENTORY)
    if digest(encoded(inventory)) != plan['inventory_sha256']:
        raise ValueError('Closed Figure inventory changed')
    query_inputs = decode(small(root / QUERY_INPUTS))
    if query_inputs != plan['query_inputs']:
        raise ValueError('Closed Figure observed-query selection changed')
    desired = set(inventory['titles']) | provider_query_titles(root, query_inputs, namespace, wiki, date)
    site_raw = small(root / ROLES['figure-sizing-site'], MAX_RESPONSE)
    raw_path = bound('raw_stream')
    offsets, used, retained_used, http_files = [], set(), set(), set()
    retained = plan['retained']
    old_planned = None

    def batches():
        nonlocal old_planned
        with raw_path.open('rb') as source, (root / FILE_REQUESTS).open('rb') as journal:
            header_line, journal_line = source.readline(STREAM_HEADER_LIMIT+1), journal.readline(STREAM_HEADER_LIMIT+1)
            if max(len(header_line), len(journal_line)) > STREAM_HEADER_LIMIT:
                raise ValueError('Closed Figure header exceeds its bound')
            expected = {'schema': RAW_STREAM_SCHEMA, 'wiki': wiki,
                'core_revision': decode(site_raw)['query']['general']['git-hash'],
                'namespace_registry_sha256': digest(namespace), 'records_count': len(desired),
                'base_batches': plan['base_batches'], 'observed_batches': 0}
            if (stream_decode(header_line) != expected or stream_decode(journal_line) !=
                    {'schema': REQUEST_STREAM_SCHEMA, 'batches': plan['base_batches']}):
                raise ValueError('Closed Figure stream headers differ')
            for index in range(committed):
                offset = source.tell()
                line, source_line = source.readline(STREAM_RAW_LINE_LIMIT+1), journal.readline(STREAM_HEADER_LIMIT+1)
                if len(line) > STREAM_RAW_LINE_LIMIT or len(source_line) > STREAM_HEADER_LIMIT:
                    raise ValueError('Closed Figure record exceeds its bound')
                batch, authority = stream_decode(line), stream_decode(source_line)
                replay_source(root, authority, batch, wiki, date, namespace, http_files)
                names = set(batch['requests'])
                if names & used or not names <= desired or 'observed_svg_width_px' in batch:
                    raise ValueError('Closed Figure prefix duplicates or adds selected names')
                if index < len(retained):
                    if authority != retained[index]:
                        raise ValueError('Closed Figure retained request order changed')
                    retained_used.update(names)
                else:
                    if old_planned is None:
                        remaining = sorted(desired-retained_used, key=lambda t:t.encode())
                        old_planned = list(metadata.title_batches(wiki, remaining, plan['batch_size'], figure_axes=True))
                        if digest(encoded(old_planned)) != plan['planned_requests_sha256']:
                            raise ValueError('Closed Figure request plan changed')
                    if authority['kind'] != 'http-archived' or batch['requests'] != old_planned[index-len(retained)]:
                        raise ValueError('Closed Figure HTTP prefix order changed')
                used.update(names)
                offsets.append((offset, len(line), digest(line)))
                yield batch
            if source.read(1) or journal.read(1):
                raise ValueError('Closed Figure prefix has trailing uncommitted data')
    result = file_records(batches(), namespace, wiki, date, site_raw, has_batches=True, record_limit=len(desired))
    if (old_planned is None or titles != old_planned[committed-len(retained)] or
            set(titles) & used or not set(titles) <= desired):
        raise ValueError('Rejected Figure request is not the next uncommitted batch')
    accounted = {*plan['defaults'], ROLES['figure-siteinfo'], ROLES['figure-sizing-raw'],
        ROLES['figure-sizing-site'], INVENTORY, PLAN, FILE_REQUESTS, QUERY_INPUTS,
        *http_files, *(row['path'] for row in query_inputs), request_path.name, receipt_path.name, rejected_path.name}
    if set(files) != accounted:
        raise ValueError('Closed Figure prefix has unrelated or rejected HTTP evidence')
    if any(evidence.stamp(p) != stamp for p, stamp in stamps.items()):
        raise ValueError('Closed Figure evidence changed during replay')
    answer = {'record': record, 'plan': plan, 'namespace': namespace, 'document': result,
        'offsets': offsets, 'raw_path': raw_path, 'stamps': stamps, 'light_titles': light,
        'failed_titles': titles, 'inventory': inventory, 'query_inputs': query_inputs}
    if cache is not None:
        cache[key] = answer
    return answer


def closed_prefix_batch(reference, cache):
    if (not isinstance(reference, dict) or set(reference) != {'kind', 'path', 'sha256', 'batch'} or
            reference['kind'] != 'closed-prefix' or type(reference['batch']) is not int):
        raise ValueError('Invalid retained closed-prefix batch')
    path = Path(reference['path'])
    if digest(small(path)) != reference['sha256']:
        raise ValueError('Closed Figure prefix record changed')
    prefix = read_closed_prefix(path, cache)
    number = reference['batch']
    if not 0 <= number < len(prefix['offsets']):
        raise ValueError('Closed Figure batch index outside accepted prefix')
    offset, size, sha = prefix['offsets'][number]
    with prefix['raw_path'].open('rb') as source:
        source.seek(offset)
        raw = source.read(size)
    if len(raw) != size or digest(raw) != sha:
        raise ValueError('Accepted Figure prefix line changed')
    return stream_decode(raw)


def check_prefix_cache(cache):
    for prefix in cache.values():
        if any(evidence.stamp(p) != stamp for p, stamp in prefix['stamps'].items()):
            raise ValueError('Closed Figure prefix changed during use')


def selected_inventory(args, namespace):
    prepared = getattr(args, 'prepared_inventory', None)
    if prepared is None:
        return source_inventory(namespace, args.wiki, args.date, small(args.dumpstatus), args.sql)
    inventory, stamps = prepared
    paths = {Path(path).resolve() for path in args.sql}
    if (set(stamps) != paths or any(evidence.stamp(path) != before for path, before in stamps.items()) or
            inventory.get('wiki') != args.wiki or inventory.get('date') != args.date or
            inventory.get('namespace_registry_sha256') != digest(namespace) or
            inventory.get('dumpstatus_raw') != small(args.dumpstatus).decode('utf-8') or
            {Path(row['path']) for row in inventory.get('sources', [])} != paths):
        raise ValueError('Invocation-local Figure inventory changed')
    return inventory


def capture_files(args, transport=None, sleep=time.sleep):
    root = Path(args.output)
    # The proof may live outside its failed generation. Reject an output inside
    # that generation before even creating the capture lock or its parent.
    for path in getattr(args, 'reuse_batch', []):
        record = decode(small(Path(path)))
        if isinstance(record, dict) and record.get('schema') == CLOSED_PREFIX_SCHEMA:
            source_root = record.get('source_root')
            if not isinstance(source_root, str) or root.resolve().is_relative_to(Path(source_root).resolve()):
                raise ValueError('Figure capture cannot modify its closed prefix source')
    root.parent.mkdir(parents=True, exist_ok=True)
    lock = root.with_name('.'+root.name+'.capture.lock')
    fd = os.open(lock, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.getuid():
            raise ValueError('Unsafe Figure capture lock')
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return _capture_files(args, transport=transport, sleep=sleep)
    finally:
        os.close(fd)


def _capture_files(args, transport=None, sleep=time.sleep):
    """Stream a selected file set, preserving each accepted response exactly once."""
    if (not re.fullmatch(r'\d{8}', args.date) or not 1 <= args.batch_size <= 50 or
            not 1 <= args.delay <= 60 or not 1 <= args.wall_seconds <= 86400):
        raise ValueError('Invalid Figure capture limits')
    root, defaults_root = Path(args.output), Path(args.defaults)
    resume_path = getattr(args, 'resume', None)
    if root.is_symlink() or (root.exists() and resume_path is None):
        raise ValueError('Figure capture output already exists; preserve original evidence')
    for source in (defaults_root, *(Path(p) for p in args.reuse),
                   *(Path(p).parent for p in getattr(args, 'reuse_batch', []))):
        if root.resolve().is_relative_to(source.resolve()):
            raise ValueError('Figure capture cannot modify a retained source')
    defaults_path = defaults_root / site_info.SNAPSHOT
    defaults = site_info.validate_snapshot(defaults_path, args.wiki, args.date)
    if defaults['profile'] != site_info.FIGURE_PROFILE:
        raise ValueError('Missing Figure default-options capture')
    artifacts = site_info.capture_artifacts(defaults_path, defaults)
    saved = {name: small(defaults_root / name) for name in artifacts}
    if any(digest(saved[name]) != expected for name, expected in artifacts.items()):
        raise ValueError('Figure defaults changed before capture')
    namespace = saved[site_info.PREFIX + 'namespace-registry.tsv']
    inventory = selected_inventory(args, namespace)
    log_paths = [Path(path) for path in getattr(args, 'log', [])]
    if len(log_paths) > 1024 or len(set(log_paths)) != len(log_paths):
        raise ValueError('Invalid or duplicate observed file query source')
    if sum(evidence.stamp(path)[2] for path in log_paths) > MAX_METADATA:
        raise ValueError('Observed file query sources exceed bounded capacity')
    if resume_path is None:
        root.mkdir(parents=True, exist_ok=False)
        query_inputs = [dict(evidence.snapshot_input(path, root, f'figure-file-query-{number:04d}.log'), kind='log')
                        for number, path in enumerate(log_paths)]
        evidence.document(root / QUERY_INPUTS, query_inputs)
    else:
        if Path(resume_path).parent.resolve() != root.resolve() or (root / COMPLETE).exists():
            raise ValueError('Resume must bind this unfinished Figure generation')
        query_inputs = decode(small(root / QUERY_INPUTS))
        if len(query_inputs) != len(log_paths):
            raise ValueError('Figure resume query inputs differ')
        for row, path in zip(query_inputs, log_paths, strict=True):
            actual = evidence.fingerprint(path)
            if any(row.get(key) != actual[key] for key in ('size', 'sha1', 'sha256')):
                raise ValueError('Figure resume query bytes differ')
    query_titles = provider_query_titles(root, query_inputs, namespace, args.wiki, args.date)
    desired, used = set(inventory['titles']) | query_titles, set()
    retained, observed, prefix_cache, light_titles = [], [], {}, set()
    closed_prefixes = []
    # Retain descriptors, not response strings. Each source is replayed lazily.
    for path in args.reuse:
        raw = small(Path(path) / MANIFEST)
        batch = retained_file_batch(path, args.wiki, args.date)
        names = set(batch['requests'])
        if names <= desired and not names & used:
            retained.append({'kind': 'retained-occurrences', 'path': str(Path(path).resolve()), 'manifest_sha256': digest(raw)})
            used.update(names)
    for path in getattr(args, 'reuse_batch', []):
        raw = small(Path(path))
        if decode(raw).get('schema') == CLOSED_PREFIX_SCHEMA:
            prefix = read_closed_prefix(Path(path), prefix_cache)
            if (closed_prefixes or prefix['record']['wiki'] != args.wiki or prefix['record']['date'] != args.date or
                    prefix['namespace'] != namespace or prefix['inventory'] != inventory or
                    prefix['query_inputs'] != query_inputs or prefix['plan']['defaults'] != artifacts):
                raise ValueError('Closed Figure prefix input selection differs')
            names = {row['requested_file'] for row in prefix['document']['records']}
            if not names <= desired or names & used:
                raise ValueError('Closed Figure prefix overlaps another selected batch')
            reference = {'kind': 'closed-prefix', 'path': str(Path(path).resolve()), 'sha256': digest(raw)}
            closed_prefixes.append(reference)
            retained.extend(dict(reference, batch=i) for i in range(len(prefix['offsets'])))
            used.update(names)
            light_titles.update(prefix['light_titles'])
            continue
        batch = retained_metadata_batch(path, args.wiki, args.date, namespace)
        names = set(batch['requests'])
        supplemental = 'observed_svg_width_px' in batch
        if not names <= desired or (names & used and not supplemental):
            raise ValueError('Retained file batch has duplicate or unselected names')
        source = {'kind': 'retained-request', 'path': str(Path(path).resolve()), 'sha256': digest(raw)}
        (observed if supplemental else retained).append(source)
        if not supplemental:
            used.update(names)
    remaining = sorted(desired - used, key=lambda name: name.encode('utf-8'))
    planned = list(metadata.title_batches(args.wiki, remaining, args.batch_size, figure_axes=True))
    if light_titles:
        if not light_titles <= set(remaining):
            raise ValueError('Metadata-light titles are not uncommitted selected names')
        split = []
        for titles in planned:
            ordinary = [title for title in titles if title not in light_titles]
            if ordinary:
                split.append(ordinary)
            split.extend([title] for title in titles if title in light_titles)
        if {title for titles in split for title in titles} != set(remaining) or sum(map(len, split)) != len(remaining):
            raise ValueError('Figure metadata transition lost or duplicated names')
        planned = split
    base_count, observed_count = len(retained)+len(planned), len(observed)
    total = base_count+observed_count
    if total > 0xffffffff or not base_count <= len(desired) <= 50*base_count or observed_count > len(desired):
        raise ValueError('Figure inventory exceeds checked stream count representation')
    raw_bound = STREAM_HEADER_LIMIT + total*STREAM_RAW_LINE_LIMIT
    projection_bound = STREAM_HEADER_LIMIT + len(desired)*STREAM_FACT_LINE_LIMIT
    if max(raw_bound, projection_bound) >= 2**64:
        raise ValueError('Figure stream plan byte count overflow')
    plan = {'schema': 'wikidict.figure-capture-plan.v1', 'wiki': args.wiki, 'date': args.date,
            'source': capture_source(), 'namespace_registry_sha256': digest(namespace),
            'inventory_sha256': digest(encoded(inventory)), 'defaults': artifacts,
            'query_inputs': query_inputs, 'retained': retained, 'observed': observed,
            'planned_requests_sha256': digest(encoded(planned)), 'records_count': len(desired),
            'base_batches': base_count, 'observed_batches': observed_count,
            'raw_byte_upper_bound': raw_bound, 'projection_byte_upper_bound': projection_bound,
            'batch_size': args.batch_size, 'delay': args.delay, 'pacing': 'start-to-start'}
    if closed_prefixes:
        plan.update(closed_prefixes=closed_prefixes, metadata_light_titles=sorted(light_titles, key=lambda t:t.encode()))
    resumes, committed, http_files = [], 0, set()
    if resume_path is not None:
        if inventory_document(root / PLAN) != plan:
            raise ValueError('Figure resume source, input or request plan changed')
        ref_id = evidence.fingerprint(Path(resume_path))
        reference = {'path': Path(resume_path).name, 'bytes': ref_id['size'], 'sha256': ref_id['sha256']}
        proof = read_resume(root, reference, plan, live=True)
        committed = proof['_failure']['committed_batches']
        resumes = [*proof['_failure'].get('resumes', []), reference]
        site_raw = small(root / ROLES['figure-sizing-site'], MAX_RESPONSE)
    else:
        for name, raw in saved.items():
            evidence.put(root / name, raw)
        evidence.put(root / ROLES['figure-siteinfo'], saved[site_info.SNAPSHOT])
        evidence.document(root / INVENTORY, inventory)
        evidence.document(root / PLAN, plan)
        site_raw = saved[site_info.SNAPSHOT]
    deadline = time.monotonic()+args.wall_seconds
    registry = evidence.Registry(namespace, args.wiki, args.date)
    pacing = metadata.RequestStartPacing(args.delay, sleep)
    raw_path, request_path = root / ROLES['figure-sizing-raw'], root / FILE_REQUESTS
    count = committed
    def retained_batch(source):
        if source['kind'] == 'closed-prefix':
            return closed_prefix_batch(source, prefix_cache)
        if source['kind'] == 'retained-occurrences':
            return retained_file_batch(Path(source['path']), args.wiki, args.date)
        return retained_metadata_batch(Path(source['path']), args.wiki, args.date, namespace)
    def iterator():
        nonlocal site_raw, count
        if committed:
            raw_size = proof['_failure']['artifacts'][ROLES['figure-sizing-raw']]['bytes']
            journal_size = proof['_failure']['artifacts'][FILE_REQUESTS]['bytes']
            with raw_path.open('rb') as old_raw, request_path.open('rb') as old_sources:
                raw_line = old_raw.readline(STREAM_HEADER_LIMIT+1)
                source_line = old_sources.readline(STREAM_HEADER_LIMIT+1)
                if max(len(raw_line), len(source_line)) > STREAM_HEADER_LIMIT:
                    raise ValueError('Figure checkpoint header exceeds its bound')
                header = stream_decode(raw_line)
                expected_header = {'schema': RAW_STREAM_SCHEMA, 'wiki': args.wiki,
                    'core_revision': decode(site_raw)['query']['general']['git-hash'],
                    'namespace_registry_sha256': digest(namespace), 'records_count': len(desired),
                    'base_batches': base_count, 'observed_batches': observed_count}
                if header != expected_header or stream_decode(source_line) != {'schema': REQUEST_STREAM_SCHEMA, 'batches': total}:
                    raise ValueError('Figure checkpoint stream headers differ')
                for index in range(committed):
                    line = old_raw.readline(STREAM_RAW_LINE_LIMIT+1)
                    source_line = old_sources.readline(STREAM_HEADER_LIMIT+1)
                    if len(line) > STREAM_RAW_LINE_LIMIT or len(source_line) > STREAM_HEADER_LIMIT:
                        raise ValueError('Figure checkpoint record exceeds its bound')
                    batch, source = stream_decode(line), stream_decode(source_line)
                    replay_source(root, source, batch, args.wiki, args.date, namespace, http_files, prefix_cache)
                    if index < len(retained):
                        if source != retained[index]:
                            raise ValueError('Figure retained prefix order differs')
                    elif index < base_count:
                        expected_kind = 'http-archived-light' if set(batch['requests']) <= light_titles else 'http-archived'
                        if batch['requests'] != planned[index-len(retained)] or source['kind'] != expected_kind:
                            raise ValueError('Figure HTTP prefix request plan differs')
                    elif source != observed[index-base_count]:
                        raise ValueError('Figure supplemental prefix order differs')
                    yield batch
                if old_raw.tell() != raw_size or old_sources.tell() != journal_size:
                    raise ValueError('Figure prefix has uncommitted or trailing bytes')
            allowed = {*saved, ROLES['figure-siteinfo'], ROLES['figure-sizing-raw'],
                       ROLES['figure-sizing-site'], INVENTORY, PLAN, FILE_REQUESTS, QUERY_INPUTS,
                       *http_files, *(row['path'] for row in query_inputs)}
            for resume in resumes:
                previous = read_resume(root, resume, plan, live=False)
                allowed.update((resume['path'], previous['failure']['path']))
            if set(payload(root)) != allowed:
                raise ValueError('Figure checkpoint contains uncommitted HTTP or publication artifacts')
        with (append_prefix(raw_path, raw_size) if committed else raw_path.open('xb')) as raw_output, \
                (append_prefix(request_path, journal_size) if committed else request_path.open('xb')) as request_output:
            if not committed:
                request_output.write(stream_encoded({'schema': REQUEST_STREAM_SCHEMA, 'batches': total}))
            for index in range(committed, total):
                accepted_path = None
                if time.monotonic() >= deadline:
                    raise ValueError('Capture wall deadline reached')
                if index < len(retained):
                    source = retained[index]
                    batch = retained_batch(source)
                elif index < base_count:
                    number = index-len(retained)+1
                    titles = planned[number-1]
                    light = set(titles) <= light_titles
                    _, reference = metadata.request_batch(root, number, titles, registry,
                        transport or evidence.get_response, sleep, deadline, args.delay, pacing, figure_axes=True,
                        figure_metadata_light=light)
                    receipt = decode(small(root / reference['accepted_receipt']))
                    attempt = int(reference['accepted_receipt'].removesuffix('.receipt.json').rsplit('-', 1)[1])
                    names = [reference['request']]
                    for attempt_number in range(1, attempt+1):
                        stem = f'file-metadata.response-{number:06d}-{attempt_number:02d}'
                        names.append(stem+'.receipt.json')
                        if (root / (stem+'.raw.json')).exists():
                            names.append(stem+'.raw.json')
                    actual, response = metadata.verified_batch(root, reference, args.wiki, set(names), figure_axes=True, figure_metadata_light=light)
                    batch = {'requests': actual, 'response': response.decode('utf-8')}
                    if light:
                        validate_metadata_light(batch, namespace, args.wiki, args.date)
                    accepted_path = root / metadata.safe_name(receipt['response'])
                    accepted_stamp = evidence.stamp(accepted_path)
                    names.remove(accepted_path.name)
                    source = {'kind': 'http-archived-light' if light else 'http-archived', 'batch': reference, 'artifacts': names}
                else:
                    source = observed[index-base_count]
                    batch = retained_batch(source)
                line = stream_encoded(batch)
                if len(line) > STREAM_RAW_LINE_LIMIT or len(batch['response'].encode()) > MAX_RESPONSE:
                    raise ValueError('Figure response record exceeds its bound')
                if index == 0:
                    site_raw = batch['response'].encode()
                    if not figure_source_compatible(decode(site_raw)['query']['general']['git-hash'],
                            decode(saved[site_info.SNAPSHOT])['query']['general'].get('git-hash')):
                        raise ValueError('Defaults and Figure observations use different source versions')
                    evidence.put(root / ROLES['figure-sizing-site'], site_raw)
                    header = {'schema': RAW_STREAM_SCHEMA, 'wiki': args.wiki,
                        'core_revision': decode(site_raw)['query']['general']['git-hash'],
                        'namespace_registry_sha256': digest(namespace), 'records_count': len(desired),
                        'base_batches': base_count, 'observed_batches': observed_count}
                    raw_output.write(stream_encoded(header))
                raw_output.write(line)
                request_output.write(stream_encoded(source))
                raw_output.flush(); os.fsync(raw_output.fileno())
                request_output.flush(); os.fsync(request_output.fileno())
                # Only the newly owned accepted duplicate is retired after its
                # exact bytes and receipt have a durable place in the raw role.
                if accepted_path is not None:
                    if evidence.stamp(accepted_path) != accepted_stamp:
                        raise ValueError('Accepted HTTP response changed before archival retirement')
                    accepted_path.unlink()
                count += 1
                replay_source(root, source, batch, args.wiki, args.date, namespace, http_files, prefix_cache)
                yield batch
            if total == 0:
                evidence.put(root / ROLES['figure-sizing-site'], site_raw)
                raw_output.write(stream_encoded({'schema': RAW_STREAM_SCHEMA, 'wiki': args.wiki,
                    'core_revision': decode(site_raw)['query']['general']['git-hash'],
                    'namespace_registry_sha256': digest(namespace), 'records_count': 0,
                    'base_batches': 0, 'observed_batches': 0}))
    try:
        batches = iterator()
        # The first response establishes the exact API epoch for the shared
        # source profile; the reducer validates each batch before requesting next.
        first = next(batches, None)
        document = file_records(itertools.chain(() if first is None else (first,), batches),
            namespace, args.wiki, args.date, site_raw, has_batches=bool(base_count), record_limit=len(desired))
        if not figure_source_compatible(document['core_revision'], decode(saved[site_info.SNAPSHOT])['query']['general'].get('git-hash')):
            raise ValueError('Defaults and Figure observations use different source versions')
        check_prefix_cache(prefix_cache)
        raw_id = evidence.fingerprint(raw_path)
        document.update(schema=FILES_STREAM_SCHEMA, records_count=len(document['records']),
            raw_bytes=raw_id['size'], raw_sha256=raw_id['sha256'], generator_sha256=producer()['generator_sha256'])
        coverage = file_coverage(document, inventory, query_titles)
        write_projection_stream(root / ROLES['figure-sizing'], document)
        with (root / PROVIDER).open('xb') as output:
            for chunk in provider_chunks(document):
                output.write(chunk)
        manifest = {'schema': SCHEMA, 'capture_format': FILES_STREAM_SCHEMA,
            **producer(), 'wiki': args.wiki, 'date': args.date,
            'namespace_registry_sha256': defaults['namespace_registry_sha256'], 'coverage': coverage,
            'artifacts': payload(root), 'resumes': resumes,
            'source_dump_files': [{**{key: row[key] for key in ('wiki', 'date', 'name', 'size', 'sha1')},
                                   'url': 'https://dumps.wikimedia.org'+row['url']}
                                  for row in inventory['sources']],
            'outputs': {role: evidence.fingerprint(root / name)['sha256'] for role, name in output_roles(root).items()}}
        evidence.document(root / MANIFEST, manifest)
        verify(root, require_complete=False)
        evidence.document(root / COMPLETE, {'schema': SCHEMA, 'manifest_sha256': digest(small(root / MANIFEST))})
        return manifest
    except BaseException as original:
        try:
            batches.close()
            number = len(resumes)+1
            failure_name = f'figure-failure-{number:04d}.json'
            evidence.document(root / failure_name, {'error': str(original), 'source': capture_source(),
                'plan_sha256': digest(encoded(plan)), 'committed_batches': count,
                'artifacts': payload(root), 'resumes': resumes})
        except BaseException as save_error:
            original.add_note('Could not preserve Figure capture failure: '+str(save_error))
        raise


def select_reuse_batches(paths, wiki, date, namespace):
    """Authenticate explicit records, then scope them by captured wiki and date."""
    if not isinstance(paths, (tuple, list)):
        raise ValueError('Invalid explicit Figure batch selection')
    selected, locators, documents, requested, observed, facts, cores = [], set(), set(), {}, set(), {}, {}
    prefix_cache = {}
    for value in paths:
        if not isinstance(value, (str, Path)):
            raise ValueError('Invalid retained Figure batch path')
        path = Path(value)
        if not path.is_absolute() or path.resolve() != path or path.is_symlink():
            raise ValueError('Unsafe explicit Figure batch path')
        raw = small(path)
        sha = digest(raw)
        if str(path) in locators or sha in documents:
            raise ValueError('Duplicate explicit Figure batch record')
        locators.add(str(path)); documents.add(sha)
        record = decode(raw)
        if (not isinstance(record, dict) or not isinstance(record.get('wiki'), str) or
                not isinstance(record.get('date'), str) or re.fullmatch(r'\d{8}', record['date']) is None):
            raise ValueError('Figure batch has no unambiguous edition/date identity')
        record_wiki, record_date = record['wiki'], record['date']
        wiktionary_api(record_wiki)
        is_prefix = record.get('schema') == CLOSED_PREFIX_SCHEMA
        if is_prefix:
            prefix = read_closed_prefix(path, prefix_cache)
            own_namespace, result = prefix['namespace'], prefix['document']
            supplement = False
        else:
            own_namespace = small(path.parent / metadata.NAMESPACE)
            evidence.Registry(own_namespace, record_wiki, record_date)
            batch = retained_metadata_batch(path, record_wiki, record_date, own_namespace)
            plain = {'requests': batch['requests'], 'response': batch['response']}
            result = file_records((plain,), own_namespace, record_wiki, record_date,
                                  batch['response'].encode(), has_batches=True, record_limit=50)
            supplement = 'observed_svg_width_px' in batch
        group = (record_wiki, record_date)
        if cores.setdefault(group, result['core_revision']) != result['core_revision']:
            raise ValueError('Explicit Figure batches mix source versions')
        for row in result['records']:
            key = (*group, row['requested_file'])
            identity = file_fact_identity(row)
            if not supplement:
                if key in requested:
                    raise ValueError('Ambiguous duplicate explicit Figure request')
                requested[key] = identity
            canonical = (*group, row['canonical_file'])
            if facts.setdefault(canonical, identity) != identity:
                raise ValueError('Conflicting explicit Figure file facts')
            if supplement:
                if canonical in observed:
                    raise ValueError('Duplicate explicit observed Figure authority')
                observed.add(canonical)
        if small(path) != raw:
            raise ValueError('Explicit Figure batch changed during authentication')
        if record_wiki != wiki:
            continue
        if record_date != date or own_namespace != namespace:
            raise ValueError('Explicit Figure batch differs from the selected edition namespace/date')
        selected.append({'kind': 'closed-prefix' if is_prefix else 'retained-request', 'path': str(path), 'sha256': sha})
    for key, identity in requested.items():
        if key in facts and facts[key] != identity:
            raise ValueError('Explicit requested file conflicts with an authenticated canonical alias')
    return selected


def require_reuse_coverage(root, selected):
    if not selected:
        return
    plan = inventory_document(Path(root) / PLAN)
    if not isinstance(plan, dict) or not isinstance(plan.get('retained'), list) or not isinstance(plan.get('observed'), list):
        raise ValueError('Complete Figure capture has no retained-batch plan')
    actual = plan['retained'] + plan['observed'] + plan.get('closed_prefixes', [])
    if any(reference not in actual for reference in selected):
        raise ValueError('Complete Figure capture does not contain the selected retained batches')


def prepare_for_build(capture_root, manifest, selected_inputs, downloads, namespace_registry, *, network=False, reuse_batches=()):
    """Prepare one normal shared capture from selected official inputs only.

    The normal resolver owns the capture lock. No discovery URL, source edit,
    or alternate capture can repair an invalid published generation here.
    """
    from argparse import Namespace
    from download_wiktionaries import BASE, select_manifest_files, validate_item

    if type(network) is not bool or not isinstance(selected_inputs, list) or not selected_inputs:
        raise ValueError('Invalid normal Figure preparation policy or selection')
    root, downloads, namespace = Path(capture_root), Path(downloads), Path(namespace_registry)
    if any(not path.is_absolute() or path.resolve() != path or path.is_symlink() for path in (root, downloads, namespace)):
        raise ValueError('Unsafe normal Figure preparation input path')
    if not root.is_dir() or not downloads.is_dir():
        raise ValueError('Missing normal Figure input root')
    wiki, date = selected_inputs[0]['wiki'], selected_inputs[0]['date']
    declared = select_manifest_files(manifest, [wiki])
    selected = {}
    for row in selected_inputs:
        validate_item(row)
        if row['wiki'] != wiki or row['date'] != date or row not in declared or row['name'] in selected:
            raise ValueError('Figure preparation differs from the selected official manifest')
        selected[row['name']] = row
    tables = ('image', 'imagelinks')
    required = {f'{wiki}-{date}-{table}.sql.gz' for table in tables}
    if not required <= set(selected):
        raise ValueError('Normal Figure preparation requires selected official image and imagelinks SQL')
    optional = f'{wiki}-{date}-linktarget.sql.gz'
    names = required | ({optional} if optional in selected else set())
    sql = [downloads/wiki/date/name for name in sorted(names)]
    namespace_raw = small(namespace, MAX_METADATA)
    site_info.namespace_identity(namespace_raw, wiki, date)
    evidence.Registry(namespace_raw, wiki, date)
    retained = select_reuse_batches(reuse_batches, wiki, date, namespace_raw)
    paths = {role:root/'figure-inputs'/filename for role,filename in {**ROLES, 'file-metadata':PROVIDER}.items()}
    generation = root/'figure-inputs'

    def selected_sources(record):
        sources = record.get('source_dump_files')
        if not isinstance(sources, list) or {row.get('name') for row in sources} != names or len(sources) != len(names):
            raise ValueError('Figure capture has a different official SQL source selection')
        for row in sources:
            expected = selected[row['name']]
            if any(row.get(key) != expected[key] for key in ('wiki','date','name','url','size','sha1')):
                raise ValueError('Figure capture differs from selected official SQL descriptors')

    if generation.is_symlink() or (generation.exists() and not generation.is_dir()):
        raise ValueError('Unsafe normal Figure capture generation')
    if (generation/COMPLETE).exists() or (generation/COMPLETE).is_symlink():
        verified = verify_tuple(paths, wiki, date)
        record = verified['figure-sizing'][0]
        if record.get('namespace_registry_sha256') != digest(namespace_raw):
            raise ValueError('Figure capture namespace differs from the normal selected registry')
        selected_sources(record)
        require_reuse_coverage(generation, retained)
        return paths
    if not network:
        raise ValueError('Missing complete Figure capture in offline metadata mode')
    resume = None
    if generation.exists():
        failures = [(int(match[1]), path) for path in generation.iterdir()
                    if (match := re.fullmatch(r'figure-failure-([0-9]{4})\.json', path.name))]
        if not failures or any(number == 0 for number,path in failures):
            raise ValueError('Unfinished Figure capture requires an authenticated closed resume proof')
        number, failure = max(failures)
        evidence.stamp(failure)
        resume = generation/f'figure-resume-{number:04d}.json'
        if not resume.exists() and not resume.is_symlink() and number == 1:
            resume = generation/'figure-resume.json'
        if not resume.exists() or resume.is_symlink():
            raise ValueError('Latest Figure failure requires its own authenticated closed resume proof')
        evidence.stamp(resume)

    capture = decode(small(root/'capture.complete.json', 2*1024*1024))
    if (capture.get('wiki') != wiki or capture.get('date') != date or capture.get('namespace_mismatches') != []
            or capture.get('source_xml') not in selected_inputs):
        raise ValueError('Figure preparation lacks the selected official namespace capture')
    dumpstatus = root/'pagetable-dumpstatus.raw.json'
    dumpstatus_raw = small(dumpstatus, MAX_METADATA)
    if capture.get('artifacts', {}).get(dumpstatus.name) != digest(dumpstatus_raw):
        raise ValueError('Figure dumpstatus differs from the authenticated namespace capture')
    for path in sql:
        if path.resolve() != path or path.is_symlink():
            raise ValueError('Unsafe official Figure SQL path')
        if evidence.stamp(path)[2] != selected[path.name]['size']:
            raise ValueError('Official Figure SQL size differs from the selected manifest')

    defaults = None
    for candidate in (root/'figure-defaults', root/'site-info'):
        if not candidate.exists() and not candidate.is_symlink():
            continue
        if candidate.is_symlink() or not candidate.is_dir():
            raise ValueError('Unsafe Figure defaults cache')
        record = site_info.validate_snapshot(candidate/site_info.SNAPSHOT, wiki, date)
        if record.get('namespace_registry_sha256') != digest(namespace_raw):
            raise ValueError('Figure defaults namespace differs from the normal selected registry')
        if record.get('profile') == site_info.FIGURE_PROFILE:
            if record.get('core') not in FIGURE_SOURCE_PROFILES:
                raise ValueError('Figure defaults require a reviewed matching handler source version')
            defaults = candidate
            break
        if candidate.name == 'figure-defaults':
            raise ValueError('Figure defaults cache has the wrong capture profile')
    if defaults is None:
        if resume is not None:
            raise ValueError('Figure resume requires its existing verified defaults capture')
        # Validate all three reviewed source leaves before either API stage.
        site_info.primary_sources(root/'site-info', prefix='site-info.source-')
    stamps = {path:evidence.stamp(path) for path in sql}
    namespace_stamp, status_stamp = evidence.stamp(namespace), evidence.stamp(dumpstatus)
    inventory = source_inventory(namespace_raw, wiki, date, dumpstatus_raw, sql)
    if {row['name'] for row in inventory['sources']} != names:
        raise ValueError('Figure SQL replay selected another source set')
    for row in inventory['sources']:
        expected = selected[row['name']]
        if row['size'] != expected['size'] or row['sha1'] != expected['sha1'] or BASE + row['url'] != expected['url']:
            raise ValueError('Figure SQL replay differs from selected official descriptors')
    inventory_names = set(inventory['titles'])
    for reference in retained:
        path = Path(reference['path'])
        if digest(small(path)) != reference['sha256']:
            raise ValueError('Selected Figure batch changed before preparation')
        if reference['kind'] == 'closed-prefix':
            prefix = read_closed_prefix(path)
            names_selected = {row['requested_file'] for row in prefix['document']['records']} | set(prefix['failed_titles'])
        else:
            names_selected = set(retained_metadata_batch(path, wiki, date, namespace_raw)['requests'])
        if not names_selected <= inventory_names:
            raise ValueError('Explicit Figure batch requests names outside the selected SQL inventory')
    if defaults is None:
        defaults = root/'figure-defaults'
        site_info.capture(Namespace(wiki=wiki, date=date, namespace_registry=namespace,
            primary_sources=root/'site-info', primary_sources_prefix='site-info.source-',
            output=defaults, delay=1, wall_seconds=180, figure_defaults=True))
    default_record = site_info.validate_snapshot(defaults/site_info.SNAPSHOT, wiki, date)
    if (default_record.get('profile') != site_info.FIGURE_PROFILE
            or default_record.get('namespace_registry_sha256') != digest(namespace_raw)
            or default_record.get('core') not in FIGURE_SOURCE_PROFILES):
        raise ValueError('Figure defaults require a reviewed matching handler source version')
    if (evidence.stamp(namespace) != namespace_stamp or evidence.stamp(dumpstatus) != status_stamp
            or any(evidence.stamp(path) != stamp for path,stamp in stamps.items())):
        raise ValueError('Official Figure preparation inputs changed before acquisition')
    record = capture_files(Namespace(wiki=wiki, date=date, defaults=defaults, dumpstatus=dumpstatus,
        sql=sql, output=generation, reuse=[], reuse_batch=[Path(row['path']) for row in retained], log=[], batch_size=50, delay=1,
        wall_seconds=86400, resume=resume,
        prepared_inventory=(inventory, stamps)))
    selected_sources(record)
    require_reuse_coverage(generation, retained)
    if (set(record.get('outputs', {})) != set(paths)
            or small(generation/COMPLETE) != encoded({'schema':SCHEMA, 'manifest_sha256':digest(small(generation/MANIFEST))})
            or decode(small(generation/MANIFEST)) != record
            or evidence.stamp(namespace) != namespace_stamp or evidence.stamp(dumpstatus) != status_stamp
            or any(evidence.stamp(path) != stamp for path,stamp in stamps.items())):
        raise ValueError('Normal Figure preparation changed before publication binding')
    for path in paths.values():
        evidence.stamp(path)
    return paths


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
    collect = commands.add_parser('capture-files', help='dated image/imagelinks inventory and bounded missing API batches')
    for name in ('wiki', 'date'):
        collect.add_argument('--' + name, required=True)
    for name in ('defaults', 'dumpstatus', 'output'):
        collect.add_argument('--' + name, type=Path, required=True)
    collect.add_argument('--sql', type=Path, action='append', required=True)
    collect.add_argument('--reuse', type=Path, action='append', default=[])
    collect.add_argument('--reuse-batch', type=Path, action='append', default=[],
                         help='existing normal request/receipt evidence record, replayed without refetching')
    collect.add_argument('--log', type=Path, action='append', default=[],
                         help='retained provider-query warnings, distinct from the dated SQL file inventory')
    collect.add_argument('--batch-size', type=int, default=50)
    collect.add_argument('--delay', type=float, default=1)
    collect.add_argument('--wall-seconds', type=int, default=3600)
    collect.add_argument('--resume', type=Path, help='authenticated closed wall-stop prefix proof')
    args = parser.parse_args()
    result = stage(args) if args.command == 'stage' else capture_files(args) if args.command == 'capture-files' else verify(args.output)
    print(encoded({key: result[key] for key in ('schema', 'wiki', 'date', 'coverage')}).decode(), end='')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError) as error:
        raise SystemExit(str(error)) from error


