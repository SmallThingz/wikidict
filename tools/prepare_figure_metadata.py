#!/usr/bin/env python3
"""Replay and stage source-backed Figure inputs and bounded file inventories.

A finite occurrence capture never implies whole-edition coverage. Both the
legacy projection and its raw authorities are replayed before normal staging.
"""
import argparse
import base64
import binascii
import copy
from compression import zstd
from datetime import datetime
import fcntl
import gzip
import hashlib
from html.parser import HTMLParser
import itertools
import json
import math
import os
from pathlib import Path
import re
import stat
import sys
import time
from urllib.parse import parse_qsl, unquote, urlsplit

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


REPLAY_CONTRACT_V1 = 'wikidict.figure-files-replay.v1'
REPLAY_CONTRACT_V2 = 'wikidict.figure-files-replay.v2'
REPLAY_CONTRACT_V3 = 'wikidict.figure-files-replay.v3'
REPLAY_CONTRACT_V4 = 'wikidict.figure-files-replay.v4'
# v5 belongs to the separately reviewed SVG-language source branch.
REPLAY_CONTRACT = 'wikidict.figure-files-replay.v6'
LEGACY_TIFF_GENERATOR = 'a6c9ffe29ead25cc5a0ffa4796bfa2c9ffd10cca5a673c56593c181356d2af87'


def replay_contract(document):
    if 'replay_contract' not in document:
        return False
    if document['replay_contract'] not in (REPLAY_CONTRACT_V1, REPLAY_CONTRACT_V2, REPLAY_CONTRACT_V3, REPLAY_CONTRACT_V4, REPLAY_CONTRACT):
        raise ValueError('Unsupported Figure replay contract')
    return True


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
# The twenty retained handler/API/config leaves are byte-identical at this
# revision. Per-response registration is still mandatory; this grants no
# HTML/parser-hook or whole-deployment equivalence.
FIGURE_RESPONSE_CORE = '889108d826914948ce34af4d0457bf048cfb0398'
# The same twenty leaves and all four TimedMediaHandler registration/config
# leaves are byte-identical at this pair. Each response keeps its exact IDs.
FIGURE_REGISTRATION_CORE = 'dd1679d74e5fac619fbef9ae4cebee31247ba10d'
FIGURE_REGISTRATION_TMH = '888c3a33fb1994019e58771710099b68085a26de'
# The same twenty media-source leaves and exact response registration pair.
FIGURE_LATEST_REGISTRATION_CORE = 'a0cd6ba0a83210a34f625417abfc1f29f0dd658f'
FIGURE_REGISTRATION_EPOCHS = (FIGURE_REGISTRATION_CORE, FIGURE_LATEST_REGISTRATION_CORE)
# This epoch preserves the V4 image model. Its WebP encoder and disabled
# video presets changed, so the reference source pins remain model anchors,
# not a claim that every current source body is byte-identical.
FIGURE_WMF4_CORE = 'd45799ff7a503ab18523e720d5e3686761c84c87'
# These observed revisions have the same qualified V4 behavior; raw echoes stay exact.
# The twenty retained 93f1cd leaves and four media IDs match bb3b67 exactly.
FIGURE_WMF4_CORES = (FIGURE_WMF4_CORE, 'bb3b6755d485f60478c87c907f0557c53117142d',
                    '93f1cdcc57c0891fb208c960a9f7fff6ca1ca35c')
FIGURE_RESPONSE_EPOCHS = (FIGURE_CURRENT_CORE, FIGURE_RESPONSE_CORE, *FIGURE_REGISTRATION_EPOCHS, *FIGURE_WMF4_CORES)
for _reviewed_core in (FIGURE_COMPATIBLE_CORE, FIGURE_CURRENT_CORE):
    FIGURE_SOURCE_PROFILES[_reviewed_core] = dict(FIGURE_SOURCE_PROFILES['0470f6c99a6456a366635bf25a517a1f951de6f5'])

FIGURE_PROFILE_V3 = 'wikimedia-imagehandler-v3'
FIGURE_PROFILE_V4 = 'wikimedia-imagehandler-v4'
FIGURE_PROFILE_V5 = 'wikimedia-imagehandler-v5'
FIGURE_GIF_PROFILE = dict(FIGURE_SOURCE_PROFILES[FIGURE_CURRENT_CORE],
    kind=FIGURE_PROFILE_V4,
    gif_handler_sha256='f9ba4542bcbfbcdaee7db0c99a463b3f97e9e1e82b0e11adcae927c6638dbf52',
    main_config_schema_sha256='cf37b0e27b01de513fa9ac81bb4424f48c9892107543a0697622c677c7a1de52',
    handler_families={**FIGURE_SOURCE_PROFILES[FIGURE_CURRENT_CORE]['handler_families'],
        'image/gif': {'handler_class': 'MediaWiki\\Media\\GIFHandler', 'mediatype': 'BITMAP'}})
FIGURE_REGISTRATION_PROFILE = dict(FIGURE_GIF_PROFILE,
    media_extensions={**FIGURE_GIF_PROFILE['media_extensions'],
        'TimedMediaHandler': FIGURE_REGISTRATION_TMH})
FIGURE_WMF4_PROFILE = dict(FIGURE_GIF_PROFILE, media_extensions={
    'PagedTiffHandler': '39dc5f487287a6921e3ba8ca6affdd6412ac1870',
    'TimedMediaHandler': '740f9aee79a2ed80dee5957cd6b9cbe9d0fc6fad',
    'PDF Handler': '6c890ba5064565386a35082e16c0d511b789ac6b',
    '3D': '43498dc2d52c37d98294e4bbf73a0e8a70bd1aea'})


def figure_profile(core, kind):
    # GIF inherits bitmap geometry. This profile does not certify animated
    # thumbnail pixels, frame selection, or deployed animation limits.
    if kind == FIGURE_PROFILE_V3:
        return FIGURE_SOURCE_PROFILES.get(core)
    if kind in (FIGURE_PROFILE_V4, FIGURE_PROFILE_V5) and core in FIGURE_RESPONSE_EPOCHS:
        if core in FIGURE_WMF4_CORES:
            selected = FIGURE_WMF4_PROFILE
        else:
            selected = FIGURE_REGISTRATION_PROFILE if core in FIGURE_REGISTRATION_EPOCHS else FIGURE_GIF_PROFILE
        if kind == FIGURE_PROFILE_V4:
            return selected
        # The additional WebP proof applies only to f458 response records.
        return dict(selected, kind=FIGURE_PROFILE_V5,
            webp_handler_core_revision=FIGURE_CURRENT_CORE,
            webp_handler_sha256='4a3fa93de539a2a13ce9cc9475af5e3e45037a5a576cac2df21139120593fe5a',
            handler_families={**selected['handler_families'],
                'image/webp': {'handler_class': 'MediaWiki\\Media\\WebPHandler', 'mediatype': 'BITMAP'}})
    raise ValueError('Unreviewed Figure handler profile or source version')


def figure_source_compatible(left, right):
    return (left == right or (left in FIGURE_SOURCE_PROFILES and right in FIGURE_SOURCE_PROFILES)
            or (left in FIGURE_RESPONSE_EPOCHS and right in FIGURE_RESPONSE_EPOCHS))


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


class ObservedFigureHTML(HTMLParser):
    """The selected single literal thumbnail response, not a general page parser."""
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.stack, self.figures, self.images, self.links = [], [], [], []
        self.roots = self.captions = 0

    def handle_starttag(self, tag, attributes):
        if tag not in ('div', 'figure', 'a', 'img', 'figcaption'):
            raise ValueError('Unexpected observed Figure HTML element')
        if len(attributes) > 32 or len({name for name, _ in attributes}) != len(attributes):
            raise ValueError('Duplicate observed Figure HTML attribute')
        raw = self.get_starttag_text()
        tail = re.sub(r'^<[A-Za-z][A-Za-z0-9]*', '', raw)
        if re.fullmatch(r'''(?:[ \t\r\n\f\v]+[A-Za-z_:][A-Za-z0-9_:-]*[ \t\r\n\f\v]*=[ \t\r\n\f\v]*(?:"[^"]*"|'[^']*'))*[ \t\r\n\f\v]*/?>''', tail) is None:
            raise ValueError('Observed Figure attributes must be complete quoted assignments')
        values = dict(attributes)
        literal = {match[1].lower():match[3] for match in re.finditer(
            r'''([A-Za-z_:][A-Za-z0-9_:-]*)[ \t\r\n\f\v]*=[ \t\r\n\f\v]*(["'])(.*?)\2''', tail, re.S)}
        if any(literal.get(name) != values[name] for name in
               ('typeof','class','width','height','data-file-width','data-file-height','href') if name in values):
            raise ValueError('Observed Figure exact attributes must retain literal values')
        if any(value is None or any(char in value for char in '<>\0') for value in literal.values()):
            raise ValueError('Invalid observed Figure attribute value')
        if (any(name == 'style' or name.startswith('on') for name in values) or
                (tag != 'img' and ('width' in values or 'height' in values))):
            raise ValueError('Unproved observed Figure style or enclosing dimensions')
        if tag == 'div':
            if self.stack or self.roots or self.figures:
                raise ValueError('Unexpected observed Figure root')
            self.roots += 1
        if tag == 'figure':
            if values.get('typeof') != 'mw:File/Thumb' or self.figures or self.stack not in ([], ['div']):
                raise ValueError('Observed Figure is not one thumbnail')
            self.figures.append(values)
        elif tag == 'a':
            if (not self.stack or self.stack[-1] != 'figure' or values.get('class') != 'mw-file-description'
                    or self.links or self.captions):
                raise ValueError('Unexpected observed Figure link')
            self.links.append(values)
        elif tag == 'img':
            if (not self.stack or self.stack[-1] != 'a' or self.images or
                    values.get('class') != 'mw-file-element' or not values.get('src')):
                raise ValueError('Observed Figure image lacks its file link')
            self.images.append(values)
        elif tag == 'figcaption':
            if not self.stack or self.stack[-1] != 'figure' or self.captions or not self.images:
                raise ValueError('Unexpected observed Figure caption')
            self.captions += 1
        if tag != 'img':
            self.stack.append(tag)

    def handle_startendtag(self, tag, attributes):
        if tag != 'img':
            raise ValueError('Unexpected self-closing observed Figure element')
        self.handle_starttag(tag, attributes)

    def handle_endtag(self, tag):
        if tag == 'div' and not self.figures:
            raise ValueError('Observed Figure root does not contain the thumbnail')
        if not self.stack or self.stack.pop() != tag:
            raise ValueError('Unbalanced observed Figure HTML')

    def parse_endtag(self, offset):
        end = self.rawdata.find('>', offset)
        if end < 0:
            return -1
        if re.fullmatch(r'</[A-Za-z][A-Za-z0-9]*[ \t\r\n]*>', self.rawdata[offset:end+1]) is None:
            raise ValueError('Malformed observed Figure closing tag')
        return super().parse_endtag(offset)

    def handle_data(self, data):
        if data.strip(' \t\r\n') and (not self.stack or self.stack[-1] != 'figcaption'):
            raise ValueError('Unexpected observed Figure text')

    def handle_comment(self, data):
        if '--' in data:
            raise ValueError('Malformed observed Figure comment')

    def handle_decl(self, declaration):
        raise ValueError('Unexpected observed Figure HTML declaration')

    def handle_pi(self, declaration):
        raise ValueError('Unexpected observed Figure processing instruction')

    def unknown_decl(self, declaration):
        raise ValueError('Unexpected observed Figure declaration')


def svg_height_observation(observation, registry, facts, batch_index):
    """Corroborate one current page/title/token observation; its parse core is unknown."""
    if (not isinstance(observation, dict) or set(observation) != {'request', 'receipt', 'response'} or
            any(not isinstance(value, str) or len(value.encode()) > MAX_RESPONSE for value in observation.values())):
        raise ValueError('Invalid bounded SVG occurrence evidence')
    request, receipt, response = (decode(observation[key].encode()) for key in ('request', 'receipt', 'response'))
    if (not isinstance(request, dict) or set(request) != {'controlled_single_token', 'full_historical_page_render',
            'input_data', 'query', 'request_count', 'url'} or request.get('controlled_single_token') is not True or
            request.get('full_historical_page_render') is not False or
            type(request.get('request_count')) is not int or request['request_count'] != 1):
        raise ValueError('SVG occurrence is not an explicit single-token observation')
    query, url = request.get('query'), request.get('url')
    if (not isinstance(query, dict) or set(query) != {'action', 'contentmodel', 'format', 'formatversion',
            'maxlag', 'prop', 'text', 'title'} or
            {key: query[key] for key in ('action', 'contentmodel', 'format', 'formatversion', 'maxlag', 'prop')} !=
            {'action': 'parse', 'contentmodel': 'wikitext', 'format': 'json', 'formatversion': '2', 'maxlag': '5', 'prop': 'text'} or
            not isinstance(url, str) or len(url.encode()) > metadata.MAX_URL):
        raise ValueError('SVG occurrence request semantics changed')
    parsed = urlsplit(url)
    if (parsed.fragment or parsed._replace(query='', fragment='').geturl() != wiktionary_api(registry.wiki) or
            sorted(parse_qsl(parsed.query, keep_blank_values=True)) != sorted(query.items())):
        raise ValueError('SVG occurrence endpoint or encoded query differs')
    title, token = query['title'], query['text']
    if (not isinstance(title, str) or not title or not isinstance(token, str) or
            any(ord(char) < 32 or ord(char) == 127 for char in title+token) or
            not token.startswith('[[') or not token.endswith(']]') or
            any(char in token[2:-2] for char in '[]{}<>')):
        raise ValueError('SVG occurrence must retain one literal file token and page title')
    file_name, separator, options = token[2:-2].partition('|')
    first, *other = options.split('|')
    height_match = re.fullmatch(r'x([1-9][0-9]*)px', first)
    if (not separator or height_match is None or
            any(re.fullmatch(r'(?:[0-9]+(?:x[0-9]*)?|x[0-9]+)px', option) for option in other)):
        raise ValueError('SVG occurrence is not an exact height-only request')
    canonical = registry.file_title(file_name)
    fact = facts.get(canonical)
    height = int(height_match[1])
    if (fact is None or fact['requested_file'] != canonical or fact['canonical_file'] != canonical or
            fact['state'] != 'eligible' or fact['mime'] not in ('image/svg+xml', 'image/svg') or
            fact['mediatype'] != 'DRAWING' or type(fact['original_width']) is not int or
            type(fact['original_height']) is not int or not 0 < fact['original_width'] < 2**32 or
            not 0 < fact['original_height'] < 2**32 or not 0 < height < 2**32):
        raise ValueError('SVG occurrence lacks exact canonical positive-axis authority')
    raw = observation['response'].encode()
    if (not isinstance(receipt, dict) or receipt.get('accepted') is not True or
            type(receipt.get('status')) is not int or receipt['status'] != 200 or
            type(receipt.get('request_count')) is not int or receipt['request_count'] != 1 or
            type(receipt.get('response_bytes')) is not int or receipt['response_bytes'] != len(raw) or receipt.get('response_sha256') != digest(raw) or
            not isinstance(receipt.get('response'), str) or
            re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', receipt['response']) is None):
        raise ValueError('SVG occurrence receipt or response identity changed')
    if not isinstance(response, dict) or set(response) != {'parse'}:
        raise ValueError('Unexpected SVG occurrence API result')
    parse = response['parse']
    if (not isinstance(parse, dict) or set(parse) != {'title', 'pageid', 'text'} or
            parse.get('title') != title or type(parse.get('pageid')) is not int or parse['pageid'] <= 0 or
            not isinstance(parse.get('text'), str) or not parse['text'] or '\0' in parse['text']):
        raise ValueError('SVG occurrence returned a different page context')
    html = ObservedFigureHTML();html.feed(parse['text']);html.close()
    if html.stack or len(html.figures) != 1 or len(html.images) != 1 or len(html.links) != 1 or html.captions != 1:
        raise ValueError('SVG occurrence does not contain exactly one completed thumbnail')
    image, link = html.images[0], html.links[0]
    href = link.get('href')
    if (not isinstance(href, str) or not href.startswith('/wiki/') or len(href.encode()) > 8192 or
            any(char in href for char in '?#&\r\n\t\\') or re.search(r'%(?![0-9A-Fa-f]{2})', href)):
        raise ValueError('SVG occurrence links to a different file')
    decoded_href = unquote(href[6:], encoding='utf-8', errors='strict')
    if (any(ord(char) < 32 or ord(char) == 127 or char in '?#\\' for char in decoded_href) or
            registry.file_title(decoded_href) != canonical):
        raise ValueError('SVG occurrence links to a different file')
    dimensions = {}
    for key in ('width', 'height', 'data-file-width', 'data-file-height'):
        value = image.get(key)
        if not isinstance(value, str) or re.fullmatch(r'[1-9][0-9]*', value) is None or int(value) >= 2**32:
            raise ValueError('SVG occurrence lacks exact positive dimensions')
        dimensions[key] = int(value)
    width, original_height = fact['original_width'], fact['original_height']
    ideal = float(width)*float(height)/float(original_height)
    upper = math.ceil(ideal)
    fit = max(1, math.floor(ideal) if math.floor(float(upper)*float(original_height)/float(width)+0.5) > height else upper)
    if (dimensions['data-file-width'] != width or dimensions['data-file-height'] != original_height or
            upper >= 2**32 or not 0 < fit < 2**32 or dimensions['width'] != fit or dimensions['height'] != height):
        raise ValueError('SVG occurrence dimensions differ from the exact observed height fit')
    return canonical, {'wiki': registry.wiki, 'title': title, 'options': options, 'height_px': height,
        'observed_width_px': fit, 'observed_height_px': height, 'batch': batch_index,
        'parse_core_binding_proven': False}


def _figure_site_profile(site_raw, general, wiki, source_profile, approved):
    if (not isinstance(source_profile, dict)
            or set(source_profile) != set(approved) | {'site_raw_sha256'}
            or {key: value for key, value in source_profile.items() if key != 'site_raw_sha256'} != approved
            or source_profile['site_raw_sha256'] != digest(site_raw)):
        raise ValueError('Unreviewed or changed figure sizing source profile')
    _figure_site_registration(decode(site_raw), general, wiki, approved)


def _figure_site_registration(site, general, wiki, approved):
    """Validate registration from this caller's already decoded response."""
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


def _figure_static_webp_axes(info, width, height):
    """Admit only explicit static f458 metadata; never infer animation state."""
    fields = _figure_metadata_map(info.get('metadata'))
    allowed = {'compression', 'animated', 'transparency', 'width', 'height',
               'bits', 'media-metadata', 'metadata'}
    if (not set(fields) <= allowed or fields.get('compression') not in ('lossy', 'lossless') or
            fields.get('animated') is not False or
            any(key in info for key in ('thumberror', 'filehidden', 'suppressed', 'filemissing'))):
        raise ValueError('Unproved static WebP axes')
    for key, expected in (('width', width), ('height', height)):
        if type(fields.get(key)) is not int or fields[key] != expected or not 0 < expected < 2**32:
            raise ValueError('Unproved static WebP axes')
    if (('transparency' in fields and type(fields['transparency']) is not bool) or
            ('bits' in fields and (type(fields['bits']) is not int or fields['bits'] != 8))):
        raise ValueError('Unproved static WebP axes')
    version = _figure_metadata_map(fields.get('metadata'))
    if (set(version) != {'_MW_WEBP_VERSION'} or type(version['_MW_WEBP_VERSION']) is not int or
            version['_MW_WEBP_VERSION'] not in (2, 3)):
        raise ValueError('Unproved static WebP metadata version')
    # The qualified handler omits this field when EXIF and XMP are absent.
    # Static/version/axes proof above remains mandatory; present values stay strict.
    if 'media-metadata' not in fields:
        return
    media = _figure_metadata_map(fields['media-metadata'])
    if (any(key in media for key in ('_error', 'error', 'errors', 'warnings')) or
            ('Orientation' in media and (type(media['Orientation']) is not int or media['Orientation'] != 1))):
        raise ValueError('Unproved static WebP orientation')


def _figure_tiff_page_axes(info, width, height, *, allow_decimal_axes=False):
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
        value = page.get(key)
        # PagedTiffImage emits canonical decimal strings for page dimensions.
        # Older replay contracts retain their original integer-only meaning.
        if allow_decimal_axes and key != 'page' and type(value) is str:
            if len(value) > 10 or re.fullmatch('[1-9][0-9]*', value) is None:
                raise ValueError('Unproved single-page TIFF axes')
            value = int(value)
        if type(value) is not int or value != expected or not 0 < value < 2**32:
            raise ValueError('Unproved single-page TIFF axes')



def _figure_tiff_default_page_axes(info, width, height):
    """Only absent page/lossy options may consume this separate authority.

    PagedTiffHandler defaults to first_page; PagedTiffImage's API dimensions
    describe page 1. Require a complete consecutive page inventory starting
    at 1, and keep this grant distinct from ordinary eligible file facts.
    """
    count = info.get('pagecount')
    if type(count) is not int or not 1 < count <= 65535:
        raise ValueError('Unproved TIFF default-page axes')
    metadata = _figure_metadata_map(info.get('metadata'))
    if ('errors' in metadata or '_error' in metadata
            or metadata.get('TIFF_METADATA_VERSION') != '1.4'):
        raise ValueError('Unproved TIFF default-page axes')
    for key, expected in (('page_count', count), ('first_page', 1), ('last_page', count)):
        if type(metadata.get(key)) is not int or metadata[key] != expected:
            raise ValueError('Unproved TIFF default-page axes')
    pages = metadata.get('page_data')
    if not isinstance(pages, list) or len(pages) != count:
        raise ValueError('Unproved TIFF default-page axes')
    for number, item in enumerate(pages, 1):
        if not isinstance(item, dict) or set(item) != {'name', 'value'}:
            raise ValueError('Unproved TIFF default-page axes')
        key = item['name']
        if not ((type(key) is int and key == number) or
                (type(key) is str and key == str(number))):
            raise ValueError('Unproved TIFF default-page axes')
        page = _figure_metadata_map(item['value'])
        if type(page.get('page')) is not int or page['page'] != number:
            raise ValueError('Unproved TIFF default-page axes')
        for axis, expected in (('width', width), ('height', height)):
            value = page.get(axis)
            if type(value) is str:
                if len(value) > 10 or re.fullmatch('[1-9][0-9]*', value) is None:
                    raise ValueError('Unproved TIFF default-page axes')
                value = int(value)
            if type(value) is not int or not 0 < value < 2**32 or (number == 1 and value != expected):
                raise ValueError('Unproved TIFF default-page axes')


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
RAW_RECORD_ENCODING = 'zstd-jsonl-v1'
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


def raw_record_encoding(header, *, allow_encoded=True):
    if 'record_encoding' not in header:
        return None
    if not allow_encoded or header['record_encoding'] != RAW_RECORD_ENCODING:
        raise ValueError('Unsupported Figure raw record encoding')
    return RAW_RECORD_ENCODING


def raw_record_decode(raw, encoding):
    """Decode one physical record before the unchanged Figure batch validators."""
    if len(raw) > STREAM_RAW_LINE_LIMIT or b'\n' in raw[:-1]:
        raise ValueError('Figure raw record exceeds its physical line bound')
    value = stream_decode(raw)
    if not ({'encoding', 'raw_bytes', 'raw_sha256', 'data'} & set(value)):
        return value
    if (encoding != RAW_RECORD_ENCODING or
            set(value) != {'encoding', 'raw_bytes', 'raw_sha256', 'data'} or
            value['encoding'] != 'zstd' or type(value['raw_bytes']) is not int or
            not 0 < value['raw_bytes'] <= STREAM_RAW_LINE_LIMIT or
            not isinstance(value['raw_sha256'], str) or
            re.fullmatch('[0-9a-f]{64}', value['raw_sha256']) is None or
            not isinstance(value['data'], str)):
        raise ValueError('Invalid Figure compressed record envelope')
    try:
        frame = base64.b64decode(value['data'], validate=True)
        if base64.b64encode(frame).decode('ascii') != value['data']:
            raise ValueError('Noncanonical Figure record base64')
        info = zstd.get_frame_info(frame)
        if (not frame.startswith(b'\x28\xb5\x2f\xfd') or info.dictionary_id != 0 or
                info.decompressed_size != value['raw_bytes'] or zstd.get_frame_size(frame) != len(frame)):
            raise ValueError('Invalid single bounded Figure Zstd frame')
        decoder = zstd.ZstdDecompressor(options={zstd.DecompressionParameter.window_log_max: 24})
        decoded = decoder.decompress(frame, max_length=value['raw_bytes'] + 1)
        if (not decoder.eof or decoder.unused_data or len(decoded) != value['raw_bytes'] or
                digest(decoded) != value['raw_sha256']):
            raise ValueError('Figure record decoded size or SHA256 differs')
    except (zstd.ZstdError, binascii.Error, UnicodeError) as error:
        raise ValueError('Invalid Figure compressed record') from error
    if b'\n' in decoded[:-1]:
        raise ValueError('Figure decoded record is not one physical line')
    result = stream_decode(decoded)
    if {'encoding', 'raw_bytes', 'raw_sha256', 'data'} & set(result):
        raise ValueError('Nested Figure compressed record')
    return result


def raw_record_encoded(batch, encoding=RAW_RECORD_ENCODING):
    raw = stream_encoded(batch)
    if len(raw) > STREAM_RAW_LINE_LIMIT:
        raise ValueError('Figure decoded response record exceeds its bound')
    if encoding is None:
        return raw
    if encoding != RAW_RECORD_ENCODING:
        raise ValueError('Unsupported Figure raw record encoding')
    frame = zstd.compress(raw, level=1)
    envelope = stream_encoded({'encoding': 'zstd', 'raw_bytes': len(raw),
        'raw_sha256': digest(raw), 'data': base64.b64encode(frame).decode('ascii')})
    return envelope if len(envelope) < len(raw) else raw


def validate_stream_header(header, schema, file_bytes):
    fields = {'schema', *STREAM_COMMON}
    if schema == FILES_STREAM_SCHEMA:
        fields.update(('content_language', 'raw_sha256', 'generator_sha256', 'source_profile', 'raw_bytes'))
        if replay_contract(header):
            fields.add('replay_contract')
    elif schema == RAW_STREAM_SCHEMA:
        if raw_record_encoding(header) is not None:
            fields.add('record_encoding')
    else:
        raise ValueError('Unknown Figure stream schema')
    if set(header) != fields or header['schema'] != schema:
        raise ValueError('Invalid Figure stream header fields')
    for name in (*STREAM_COUNTS, *(['raw_bytes'] if schema == FILES_STREAM_SCHEMA else [])):
        if type(header[name]) is not int or not 0 <= header[name] < 2**64:
            raise ValueError('Invalid Figure stream count or byte length')
    count, base, observed = (header[name] for name in STREAM_COUNTS)
    if not base <= count <= 50 * base or (count == 0 and observed != 0) or base + observed > 0xffffffff:
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


def stream_values(path, schema, *, allow_encoded=True, identity_out=None, record_offsets=None):
    """Yield the header and exact declared records with bounded transient input."""
    path = Path(path)
    if identity_out is not None and (type(identity_out) is not dict or identity_out):
        raise ValueError('Stream identity output must be an empty dictionary')
    if record_offsets is not None and (type(record_offsets) is not list or record_offsets or schema != RAW_STREAM_SCHEMA):
        raise ValueError('Raw stream index output must be an empty list')
    before = evidence.stamp(path)
    sha = hashlib.sha256() if identity_out is not None else None
    size = 0
    with path.open('rb') as source:
        if sha is not None:
            opened = os.fstat(source.fileno())
            if (not stat.S_ISREG(opened.st_mode) or
                    (opened.st_dev, opened.st_ino, opened.st_size, opened.st_mtime_ns, opened.st_ctime_ns) != before):
                raise ValueError('Figure stream replaced before reading')
        raw = source.readline(STREAM_HEADER_LIMIT + 1)
        if len(raw) > STREAM_HEADER_LIMIT:
            raise ValueError('Figure stream header exceeds its bound')
        if sha is not None:
            sha.update(raw); size += len(raw)
        header = stream_decode(raw)
        count = validate_stream_header(header, schema, before[2] - len(raw))
        encoding = raw_record_encoding(header, allow_encoded=allow_encoded) if schema == RAW_STREAM_SCHEMA else None
        yield header
        limit = STREAM_RAW_LINE_LIMIT if schema == RAW_STREAM_SCHEMA else STREAM_FACT_LINE_LIMIT
        for _ in range(count):
            offset = source.tell() if record_offsets is not None else None
            raw = source.readline(limit + 1)
            if len(raw) > limit:
                raise ValueError('Figure stream record exceeds its bound')
            if sha is not None:
                sha.update(raw); size += len(raw)
            if record_offsets is not None:
                record_offsets.append((offset, len(raw), digest(raw)))
            yield raw_record_decode(raw, encoding) if schema == RAW_STREAM_SCHEMA else stream_decode(raw)
        if source.read(1):
            raise ValueError('Trailing Figure stream records or bytes')
        if sha is not None:
            opened = os.fstat(source.fileno())
            if (not stat.S_ISREG(opened.st_mode) or
                    (opened.st_dev, opened.st_ino, opened.st_size, opened.st_mtime_ns, opened.st_ctime_ns) != before):
                raise ValueError('Figure stream changed during reading')
    if evidence.stamp(path) != before:
        raise ValueError('Figure stream changed during replay')
    if sha is not None:
        if size != before[2]:
            raise ValueError('Figure stream byte count changed during replay')
        # Publish only after complete iteration, exact EOF and both identities.
        # Closing or failing this generator cannot leave a success identity.
        identity_out.update(size=size, sha256=sha.hexdigest())


def figure_stream_document(raw_path, namespace_raw, wiki, date, site_raw, *, profile_kind=FIGURE_PROFILE_V3, allow_tiff_companion=True, allow_encoded=True, allow_compatible_epochs=True, allow_decimal_tiff_axes=True, allow_default_tiff_page=True):
    before = evidence.stamp(Path(raw_path))
    identity = {}
    values = stream_values(raw_path, RAW_STREAM_SCHEMA, allow_encoded=allow_encoded, identity_out=identity)
    header = next(values)
    result = file_records(values, namespace_raw, wiki, date, site_raw,
                          has_batches=bool(header['base_batches']), record_limit=header['records_count'],
                          profile_kind=profile_kind, allow_tiff_companion=allow_tiff_companion,
                          allow_compatible_epochs=allow_compatible_epochs,
                          allow_decimal_tiff_axes=allow_decimal_tiff_axes,
                          allow_default_tiff_page=allow_default_tiff_page)
    for name in ('wiki', 'core_revision', 'namespace_registry_sha256', 'base_batches', 'observed_batches'):
        if result[name] != header[name]:
            raise ValueError('Figure raw stream differs from its declared identity or counts')
    if len(result['records']) != header['records_count']:
        raise ValueError('Figure raw stream has incomplete file membership')
    if evidence.stamp(Path(raw_path)) != before:
        raise ValueError('Figure raw stream changed after replay')
    result.update(schema=FILES_STREAM_SCHEMA, records_count=len(result['records']),
                  raw_bytes=identity['size'], raw_sha256=identity['sha256'],
                  generator_sha256=producer()['generator_sha256'], replay_contract=REPLAY_CONTRACT)
    return result


def write_projection_stream(path, document, *, identity_out=None):
    if identity_out is not None and (type(identity_out) is not dict or identity_out):
        raise ValueError('Projection identity output must be an empty dictionary')
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
        if identity_out is not None:
            output.flush()
            opened = os.fstat(output.fileno())
            written = (opened.st_dev, opened.st_ino, opened.st_size, opened.st_mtime_ns, opened.st_ctime_ns)
            if not stat.S_ISREG(opened.st_mode) or evidence.stamp(Path(path)) != written:
                raise ValueError('Figure projection replaced during writing')
    if identity_out is not None:
        if evidence.stamp(Path(path)) != written:
            raise ValueError('Figure projection replaced after writing')
        identity_out.update(stamp=written)


class _ReprojectionRecords:
    """Own one source-derived result until its written bytes are compared once."""
    def __init__(self, raw_path, namespace_raw, wiki, date, site_raw, contract, **options):
        if (type(namespace_raw) is not bytes or type(site_raw) is not bytes or
                type(wiki) is not str or type(date) is not str or
                contract not in (REPLAY_CONTRACT_V4, REPLAY_CONTRACT)):
            raise ValueError('Invalid private reprojection source context')
        if (set(options) != {'profile_kind', 'allow_tiff_companion', 'allow_encoded',
                'allow_compatible_epochs', 'allow_decimal_tiff_axes', 'allow_default_tiff_page'} or
                options['profile_kind'] not in (FIGURE_PROFILE_V3, FIGURE_PROFILE_V4, FIGURE_PROFILE_V5) or
                any(type(value) is not bool for key, value in options.items() if key != 'profile_kind')):
            raise ValueError('Invalid private reprojection replay options')
        self._raw_path = Path(raw_path)
        self._context = (namespace_raw, wiki, date, site_raw, contract)
        self._options = dict(options)
        self._used = False
        self._document = None
        self._identity = self._source_identity()
        document = figure_stream_document(raw_path, namespace_raw, wiki, date, site_raw, **options)
        self.check_source()
        document['replay_contract'] = contract
        self._document = document

    def _source_identity(self):
        path = self._raw_path
        if not path.is_absolute() or path.resolve(strict=True) != path:
            raise ValueError('Reprojection raw path changed')
        value = path.lstat()
        parent = path.parent.stat()
        if not stat.S_ISREG(value.st_mode) or not stat.S_ISDIR(parent.st_mode):
            raise ValueError('Reprojection raw source is not regular')
        return ((value.st_dev, value.st_ino, value.st_mode, value.st_uid, value.st_gid,
                 value.st_size, value.st_mtime_ns, value.st_ctime_ns, value.st_nlink),
                (parent.st_dev, parent.st_ino, parent.st_mode, parent.st_uid, parent.st_gid))

    def check_source(self):
        if self._source_identity() != self._identity:
            raise ValueError('Reprojection raw source changed after derivation')

    def header(self):
        if self._used or self._document is None:
            raise ValueError('Reprojection records were already consumed')
        return copy.deepcopy({key: value for key, value in self._document.items() if key != 'records'})

    def write(self, path):
        document = self.header()
        # The writer cannot mutate the expected graph. Copy only the current
        # record, including rare nested occurrence facts, never the whole list.
        document['records'] = (copy.deepcopy(row) for row in self._document['records'])
        self.check_source()
        write_projection_stream(path, document)
        self.check_source()

    def coverage(self, inventory, query_titles):
        if self._used or self._document is None:
            raise ValueError('Reprojection records were already consumed')
        self.check_source()
        return file_coverage(self._document, inventory, query_titles)

    def take(self, raw_path, namespace_raw, wiki, date, site_raw, contract, **options):
        if self._used or self._document is None:
            raise ValueError('Reprojection records were already consumed')
        if (Path(raw_path) != self._raw_path or
                (namespace_raw, wiki, date, site_raw, contract) != self._context or options != self._options):
            raise ValueError('Reprojection replay context differs')
        self.check_source()
        document = self._document
        self._document = None
        self._used = True
        return document


def verify_stream_document(projection_path, raw_path, namespace_raw, wiki, date, site_raw, *, regenerate_projection=None, _reprojection_records=None):
    if _reprojection_records is not None and (type(_reprojection_records) is not _ReprojectionRecords or regenerate_projection is not None):
        raise ValueError('Invalid private reprojection record reuse')
    if regenerate_projection is None:
        values = stream_values(projection_path, FILES_STREAM_SCHEMA)
        header = next(values)
    else:
        request = regenerate_projection
        if (type(request) is not dict or set(request) != {'header', 'mode', 'mtime_ns'} or
                type(request['header']) is not dict or type(request['mode']) is not int or
                request['mode'] not in (0o600, 0o644) or type(request['mtime_ns']) is not int or
                not 0 <= request['mtime_ns'] < 2**63):
            raise ValueError('Invalid Figure projection regeneration request')
        # The request supplies an old header, never trusted facts. Derive all
        # records here and still compare the written projection below.
        header_raw = stream_encoded(request['header'])
        if len(header_raw) > STREAM_HEADER_LIMIT:
            raise ValueError('Figure projection header exceeds its bound')
        header = stream_decode(header_raw)
        validate_stream_header(header, FILES_STREAM_SCHEMA, 2**64-1)
        publication_mode, publication_mtime = request['mode'], request['mtime_ns']
        projection_path, raw_path = Path(projection_path), Path(raw_path)
        if (not projection_path.is_absolute() or projection_path.parent != raw_path.parent or
                projection_path.parent.resolve() != projection_path.parent or
                projection_path.parent.stat().st_uid != os.geteuid() or
                os.path.lexists(projection_path)):
            raise ValueError('Figure projection regeneration requires an absent owned sibling')
        def generation_identity():
            if projection_path.parent.stat().st_uid != os.geteuid():
                raise ValueError('Figure projection directory ownership changed')
            return (raw_path.resolve(), evidence.stamp(raw_path),
                    complete_capture_directory_stamp(projection_path.parent))
        generation_before = generation_identity()
    profile = header['source_profile']
    kind = profile.get('kind') if isinstance(profile, dict) else FIGURE_PROFILE_V3
    options = dict(profile_kind=kind,
        allow_tiff_companion=replay_contract(header) or header['generator_sha256'] == LEGACY_TIFF_GENERATOR,
        allow_encoded=header.get('replay_contract') in (REPLAY_CONTRACT_V2, REPLAY_CONTRACT_V3, REPLAY_CONTRACT_V4, REPLAY_CONTRACT),
        allow_compatible_epochs=header.get('replay_contract') in (REPLAY_CONTRACT_V3, REPLAY_CONTRACT_V4, REPLAY_CONTRACT),
        allow_decimal_tiff_axes=header.get('replay_contract') in (REPLAY_CONTRACT_V4, REPLAY_CONTRACT),
        allow_default_tiff_page=header.get('replay_contract') == REPLAY_CONTRACT)
    expected = (figure_stream_document(raw_path, namespace_raw, wiki, date, site_raw, **options)
                if _reprojection_records is None else
                _reprojection_records.take(raw_path, namespace_raw, wiki, date, site_raw,
                                          header.get('replay_contract'), **options))
    expected_header = {key: value for key, value in expected.items() if key != 'records'}
    expected_header['generator_sha256'] = header['generator_sha256']
    if not replay_contract(header):
        expected_header.pop('replay_contract')
    else:
        expected_header['replay_contract'] = header['replay_contract']
    if header != expected_header:
        raise ValueError('Figure projection stream header differs from exact raw replay')
    if regenerate_projection is not None:
        if generation_identity() != generation_before:
            raise ValueError('Figure source changed before projection generation')
        written_identity = {}
        write_projection_stream(projection_path, dict(header, records=expected['records']),
                                identity_out=written_identity)
        with projection_path.open('rb') as published:
            opened = os.fstat(published.fileno())
            if (not stat.S_ISREG(opened.st_mode) or opened.st_uid != os.geteuid() or
                    (opened.st_dev, opened.st_ino, opened.st_size, opened.st_mtime_ns, opened.st_ctime_ns) != written_identity['stamp']):
                raise ValueError('Generated Figure projection opened identity changed')
            os.fchmod(published.fileno(), publication_mode)
            os.utime(published.fileno(), ns=(publication_mtime, publication_mtime))
            os.fsync(published.fileno())
            opened = os.fstat(published.fileno())
            published_identity = (opened.st_dev, opened.st_ino, opened.st_size, opened.st_mtime_ns, opened.st_ctime_ns)
        if evidence.stamp(projection_path) != published_identity:
            raise ValueError('Generated Figure projection publication identity changed')
        generation_published = generation_identity()
        if (generation_published[:2] != generation_before[:2] or
                generation_published[2][:3] != generation_before[2][:3]):
            raise ValueError('Figure source identity changed during projection generation')
        values = stream_values(projection_path, FILES_STREAM_SCHEMA)
        if next(values) != header:
            raise ValueError('Generated Figure projection header changed')
    for record in expected['records']:
        if next(values) != record:
            raise ValueError('Figure projection stream record differs from exact raw replay')
    if next(values, None) is not None:
        raise ValueError('Figure projection has unexpected trailing records')
    if _reprojection_records is not None:
        _reprojection_records.check_source()
    if regenerate_projection is not None:
        if generation_identity() != generation_published or evidence.stamp(projection_path) != published_identity:
            raise ValueError('Figure source changed during generated projection verification')
    return dict(header, records=expected['records'])


def file_fact_identity(record):
    return tuple(record[key] for key in ('canonical_file', 'state', 'file_sha1',
        'file_timestamp', 'original_width', 'original_height', 'mime', 'mediatype'))


def tiff_metadata_companion(batch, data, rows, registry, wiki, core, language, approved):
    """Corroborate a TIFF-only response without modifying either API document."""
    raw = batch['tiff_metadata_response']
    if not isinstance(raw, str) or not raw or len(raw.encode('utf-8')) > MAX_RESPONSE:
        raise ValueError('Invalid bounded TIFF metadata response')
    pages = {page['title']: page for page in data['query']['pages']}
    titles = [title for title in batch['requests'] if rows[title]['exists'] and
              pages[rows[title]['response_title']]['imageinfo'][0].get('mime') == 'image/tiff']
    if not titles:
        raise ValueError('TIFF metadata response has no positive TIFF requests')
    companion = decode(raw.encode('utf-8'))
    require_edition(companion, wiki)
    general = companion['query']['general']
    if general.get('git-hash') != core or general.get('lang') != language:
        raise ValueError('TIFF metadata response changed site or source version')
    _figure_site_profile(raw.encode('utf-8'), general, wiki,
                        dict(approved, site_raw_sha256=digest(raw.encode('utf-8'))), approved)
    observed = companion.get('curtimestamp')
    if not isinstance(observed, str) or not re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z', observed):
        raise ValueError('Missing same-response TIFF observation time')
    observed_key = _figure_utc_key(observed)
    actual = metadata.classify_response(companion, titles, registry)
    other_pages = {page['title']: page for page in companion['query']['pages']}
    result = {}
    for title in titles:
        row = rows[title]
        if actual[title] != row:
            raise ValueError('TIFF metadata response changed complete file identity')
        original = pages[row['response_title']]['imageinfo'][0]
        info = other_pages[actual[title]['response_title']]['imageinfo'][0]
        if ('metadata' in original or 'metadata' not in info or info.get('mime') != 'image/tiff' or
                info.get('size') != original.get('size') or
                _figure_utc_key(row['file_timestamp']) > observed_key):
            raise ValueError('TIFF metadata response is incomplete or conflicts with lean evidence')
        if ('pagecount' in original) != ('pagecount' in info) or ('pagecount' in original and (
                type(original['pagecount']) is not int or type(info['pagecount']) is not int or
                original['pagecount'] != info['pagecount'])):
            raise ValueError('TIFF metadata response changed explicit page count')
        result[title] = info
    return result


def jpeg_unrotated_metadata(info):
    value = info.get('metadata')
    if not isinstance(value, list) or not 1 <= len(value) <= 4096:
        return False
    fields = {}
    for item in value:
        if (not isinstance(item, dict) or set(item) != {'name', 'value'} or
                not isinstance(item['name'], str) or item['name'] in fields):
            return False
        fields[item['name']] = item['value']
    if 'errors' in fields:
        return False
    if '_error' in fields:
        return len(fields) == 1 and fields['_error'] == '0'
    return 'Orientation' not in fields or (type(fields['Orientation']) is int and fields['Orientation'] == 1)


def file_records(batches, namespace_raw, wiki, date, site_raw, *, has_batches, record_limit,
                 profile_kind=FIGURE_PROFILE_V3, allow_tiff_companion=True, allow_compatible_epochs=False, allow_decimal_tiff_axes=True, allow_default_tiff_page=True):
    registry = evidence.Registry(namespace_raw, wiki, date)
    registration = decode(site_raw)
    require_edition(registration, wiki)
    site_general = registration['query']['general']
    core = site_general.get('git-hash')
    language = site_general.get('lang')
    if (not isinstance(core, str) or re.fullmatch('[0-9a-f]{40}', core) is None or
            not isinstance(language, str) or '# content-language\t'+language not in namespace_raw.decode().splitlines()):
        raise ValueError('Figure file site/namespace identity mismatch')
    if (core in (FIGURE_RESPONSE_CORE, *FIGURE_REGISTRATION_EPOCHS, *FIGURE_WMF4_CORES) or profile_kind == FIGURE_PROFILE_V5) and not allow_compatible_epochs:
        raise ValueError('Compatible response epochs require replay contract v3')
    profile = None
    if has_batches:
        approved = figure_profile(core, profile_kind)
        if approved is None:
            raise ValueError('Unreviewed Figure handler source version; retain the response for source reconciliation')
        profile = dict(approved, site_raw_sha256=digest(site_raw))
        _figure_site_registration(registration, site_general, wiki, approved)
    records, seen, canonical_facts, observed_files, height_keys = [], set(), {}, set(), set()
    jpeg_evidence, jpeg_supplemented = {}, set()
    observing = False
    base_count = observed_count = 0
    for batch_index, batch in enumerate(batches):
        if (not isinstance(batch, dict) or set(batch) not in ({'requests', 'response'},
                {'requests', 'response', 'tiff_metadata_response'}, {'requests', 'response', 'jpeg_metadata_only'},
                {'requests', 'response', 'observed_svg_width_px'}, {'requests', 'response', 'observed_svg_occurrences'}) or
                not isinstance(batch['response'], str) or not isinstance(batch['requests'], list) or
                not 1 <= len(batch['requests']) <= 50):
            raise ValueError('Invalid Figure source batch')
        if 'tiff_metadata_response' in batch and not allow_tiff_companion:
            raise ValueError('TIFF companion requires its qualified current producer')
        jpeg_supplement = 'jpeg_metadata_only' in batch
        if jpeg_supplement and (batch['jpeg_metadata_only'] is not True or not allow_compatible_epochs or
                profile_kind not in (FIGURE_PROFILE_V4, FIGURE_PROFILE_V5)):
            raise ValueError('JPEG supplement requires explicit qualified file replay')
        observation = batch.get('observed_svg_width_px')
        occurrences = batch.get('observed_svg_occurrences')
        supplemental = 'observed_svg_width_px' in batch or 'observed_svg_occurrences' in batch or jpeg_supplement
        if 'observed_svg_occurrences' in batch:
            if (profile_kind not in (FIGURE_PROFILE_V4, FIGURE_PROFILE_V5) or core not in (FIGURE_CURRENT_CORE, FIGURE_REGISTRATION_CORE) or
                    not isinstance(occurrences, list) or not 1 <= len(occurrences) <= 50 or
                    len(stream_encoded(batch)) > STREAM_RAW_LINE_LIMIT):
                raise ValueError('Invalid bounded SVG occurrence batch or profile')
        if supplemental:
            if 'observed_svg_width_px' in batch and (type(observation) is not int or not 0 < observation < 2**32):
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
        if any(not isinstance(title, str) for title in titles) or len(set(titles)) != len(titles):
            raise ValueError('Duplicate or invalid Figure batch request')
        for title in titles:
            if (not isinstance(title, str) or registry.file_title(title) != title or
                    any(char in title for char in '\t\r\n\0') or
                    (title not in canonical_facts if jpeg_supplement else title not in seen if supplemental else title in seen)):
                raise ValueError('Duplicate or noncanonical Figure source request')
            if not jpeg_supplement:
                seen.add(title)
        if len(metadata.query_url(wiki, titles, figure_axes=True)) > metadata.MAX_URL:
            raise ValueError('Figure source batch exceeds URL bound')
        if record_limit is not None and len(seen) > record_limit:
            raise ValueError('Figure file inventory exceeds bounded capacity')
        data = decode(response_raw)
        require_edition(data, wiki)
        general = data['query']['general']
        batch_core = general.get('git-hash')
        if (general.get('lang') != language or (batch_core != core and not (
                allow_compatible_epochs and profile_kind in (FIGURE_PROFILE_V4, FIGURE_PROFILE_V5) and
                core in FIGURE_RESPONSE_EPOCHS and batch_core in FIGURE_RESPONSE_EPOCHS))):
            raise ValueError('Figure batches mix site/source versions')
        if occurrences is not None and batch_core not in (FIGURE_CURRENT_CORE, FIGURE_REGISTRATION_CORE):
            raise ValueError('Compatible response epochs do not grant HTML occurrence authority')
        batch_profile = figure_profile(batch_core, profile_kind)
        # Exact per-core registrations differ, but the proved image profile does
        # not. Both complete registration inventories are checked below.
        if ({key: value for key, value in batch_profile.items() if key != 'media_extensions'} !=
                {key: value for key, value in approved.items() if key != 'media_extensions'}):
            raise ValueError('Figure response changed its proved handler profile')
        # This exact response was decoded above. Its constructed profile/hash
        # compared the same bytes with themselves; keep every registration check.
        _figure_site_registration(data, general, wiki, batch_profile)
        observed = data.get('curtimestamp')
        if not isinstance(observed, str) or not re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z', observed):
            raise ValueError('Missing same-response Figure observation time')
        observed_key = _figure_utc_key(observed)
        rows = metadata.classify_response(data, titles, registry)
        pages = {page['title']: page for page in data['query']['pages']}
        tiff_info = (tiff_metadata_companion(batch, data, rows, registry, wiki, batch_core, language, batch_profile)
                     if 'tiff_metadata_response' in batch else {})
        height_facts = {}
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
                if mime == 'image/webp' and batch_core != FIGURE_CURRENT_CORE:
                    family = None
                if family is not None and row['mediatype'] != family['mediatype']:
                    raise ValueError('Source handler and MediaWiki type conflict')
                eligible = family is not None and row['width'] > 0 and row['height'] > 0
                if mime == 'image/webp' and family is not None:
                    try:
                        _figure_static_webp_axes(info, row['width'], row['height'])
                    except ValueError:
                        eligible = False
                default_tiff_page = False
                if mime == 'image/tiff':
                    try:
                        _figure_tiff_page_axes(tiff_info.get(title, info), row['width'], row['height'], allow_decimal_axes=allow_decimal_tiff_axes)
                    except ValueError:
                        eligible = False
                        if allow_default_tiff_page and family is not None and row['width'] > 0 and row['height'] > 0:
                            try:
                                _figure_tiff_default_page_axes(tiff_info.get(title, info), row['width'], row['height'])
                                default_tiff_page = True
                            except ValueError:
                                pass
                record.update(canonical_file=row['canonicaltitle'],
                    state='eligible' if eligible else 'tiff_default_page' if default_tiff_page else 'unsupported', file_sha1=row['file_sha1'],
                    file_timestamp=row['file_timestamp'], original_width=row['width'],
                    original_height=row['height'], mime=mime, mediatype=row['mediatype'])
            facts = file_fact_identity(record)
            previous = (canonical_facts.get(record['canonical_file']) if jpeg_supplement else
                        canonical_facts.setdefault(record['canonical_file'], facts))
            if previous != facts:
                raise ValueError('Conflicting canonical file facts across Figure batches')
            if jpeg_supplement:
                canonical = record['canonical_file']
                proof = jpeg_evidence.get(canonical)
                if (record['requested_file'] != canonical or record['state'] != 'eligible' or
                        record['mime'] != 'image/jpeg' or record['mediatype'] != 'BITMAP' or
                        proof is None or not proof['omitted'] or proof['veto'] or canonical in jpeg_supplemented or
                        proof['repository'] != pages[row['response_title']]['imagerepository'] or
                        type(info.get('size')) is not int or proof['size'] != info['size'] or
                        not jpeg_unrotated_metadata(info)):
                    raise ValueError('JPEG supplement does not complete exact omitted file metadata')
                jpeg_supplemented.add(canonical)
                continue
            if not supplemental and record['mime'] == 'image/jpeg' and record['state'] == 'eligible':
                repository, size = pages[row['response_title']]['imagerepository'], info.get('size')
                if type(size) is not int or size < 0:
                    raise ValueError('JPEG base file size is not a nonnegative integer')
                canonical = record['canonical_file']
                proof = jpeg_evidence.setdefault(canonical, dict(repository=repository, size=size, omitted=False, veto=False))
                if proof['repository'] != repository or proof['size'] != size:
                    raise ValueError('JPEG alias changed repository or file size')
                proof['omitted'] |= 'metadata' not in info
                proof['veto'] |= 'metadata' in info and not jpeg_unrotated_metadata(info)
            if occurrences is not None:
                if record['requested_file'] != record['canonical_file']:
                    raise ValueError('SVG occurrence does not grant canonical alias fallback')
                height_facts[title] = record
                continue
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
        if occurrences is not None:
            used = set()
            for item in occurrences:
                canonical, value = svg_height_observation(item, registry, height_facts, batch_index)
                key = (value['wiki'], value['title'], canonical, value['options'], value['height_px'])
                if key in height_keys:
                    raise ValueError('Duplicate exact SVG occurrence authority')
                height_keys.add(key);used.add(canonical)
                for base in records:
                    if base['requested_file'] == canonical and base['canonical_file'] == canonical:
                        base.setdefault('observed_svg_heights', []).append(value)
            if used != set(titles):
                raise ValueError('SVG occurrence batch has unaccounted identity requests')
    for record in records:
        target = canonical_facts.get(record['requested_file'])
        facts = file_fact_identity(record)
        if target is not None and target != facts:
            raise ValueError('Requested file conflicts with an authenticated canonical alias')
    records.sort(key=lambda row: row['requested_file'].encode('utf-8'))
    return {'wiki': wiki, 'content_language': language, 'core_revision': core,
            'namespace_registry_sha256': digest(namespace_raw), 'source_profile': profile,
            'records': records, 'base_batches': base_count, 'observed_batches': observed_count}


def figure_file_document(raw, namespace_raw, wiki, date, site_raw, *, profile_kind=FIGURE_PROFILE_V3, allow_tiff_companion=True, allow_compatible_epochs=True, allow_decimal_tiff_axes=True, allow_default_tiff_page=True):
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
                          has_batches=bool(envelope['batches']), record_limit=MAX_TITLES,
                          profile_kind=profile_kind, allow_tiff_companion=allow_tiff_companion,
                          allow_compatible_epochs=allow_compatible_epochs,
                          allow_decimal_tiff_axes=allow_decimal_tiff_axes,
                          allow_default_tiff_page=allow_default_tiff_page)
    del result['base_batches'], result['observed_batches']
    result.update(schema=FILES_SCHEMA, raw_sha256=digest(raw), generator_sha256=producer()['generator_sha256'], replay_contract=REPLAY_CONTRACT)
    if len(encoded(result)) > MAX_METADATA:
        raise ValueError('Figure file projection exceeds bounded capacity')
    return result


def verify_figure_file_document(projection, raw, namespace_raw, wiki, date, site_raw):
    if (not isinstance(projection, dict) or not isinstance(projection.get('generator_sha256'), str) or
            re.fullmatch('[0-9a-f]{64}', projection['generator_sha256']) is None):
        raise ValueError('Invalid Figure file generator provenance')
    profile = projection.get('source_profile')
    kind = profile.get('kind') if isinstance(profile, dict) else FIGURE_PROFILE_V3
    expected = figure_file_document(raw, namespace_raw, wiki, date, site_raw, profile_kind=kind,
        allow_tiff_companion=replay_contract(projection) or projection['generator_sha256'] == LEGACY_TIFF_GENERATOR,
        allow_compatible_epochs=projection.get('replay_contract') in (REPLAY_CONTRACT_V3, REPLAY_CONTRACT_V4, REPLAY_CONTRACT),
        allow_decimal_tiff_axes=projection.get('replay_contract') in (REPLAY_CONTRACT_V4, REPLAY_CONTRACT),
        allow_default_tiff_page=projection.get('replay_contract') == REPLAY_CONTRACT)
    expected['generator_sha256'] = projection['generator_sha256']
    if not replay_contract(projection):
        expected.pop('replay_contract')
    else:
        expected['replay_contract'] = projection['replay_contract']
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
        table = path.name.removeprefix(f'{wiki}-{date}-').removesuffix('.sql.gz')
        job = status['jobs'].get(table+'table')
        if not isinstance(job, dict) or not isinstance(job.get('files'), dict):
            raise ValueError('Missing dated Figure SQL job authority')
        expected = job['files'].get(path.name)
        if not isinstance(expected, dict):
            raise ValueError('Missing dated Figure SQL file authority')
        url = f'/{wiki}/{date}/{path.name}'
        if (job.get('status') != 'done' or type(expected.get('size')) is not int or
                expected['size'] <= 0 or stamps[path][2] != expected['size'] or
                not isinstance(expected.get('sha1'), str) or re.fullmatch('[0-9a-f]{40}', expected['sha1']) is None or
                expected.get('url') != url):
            raise ValueError('Figure SQL differs from exact dated dumpstatus authority')
        # Official compressed size bounds the streamed hash. SQL decoding keeps
        # its per-line bound; the caller owns the whole job's time and memory.
        identity = evidence.fingerprint(path)
        if identity['size'] != expected['size'] or identity['sha1'] != expected['sha1']:
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


def inventory_runtime_authority():
    # Preserve real helper locations as well as their content identities.
    helpers = [Path(module.__file__).absolute() for module in (evidence, metadata, site_info)]
    helpers.append(Path(__file__).absolute())
    helpers.extend(evidence.REPO / name for name in evidence.dependencies())
    return (capture_source(), tuple((str(path), str(path.resolve()), evidence.stamp(path))
                                   for path in sorted(set(helpers))))


def inventory_physical_authority(paths):
    return (inventory_runtime_authority(),
            tuple((str(path), str(path.resolve()), evidence.stamp(path)) for path in paths))


def check_inventory_replay_entry(entry):
    if inventory_physical_authority(entry['paths']) != entry['authority']:
        raise ValueError('Figure inventory source or helper changed during invocation')
    for path, expected in zip(entry['paths'], entry['identities'], strict=True):
        if evidence.fingerprint(path) != expected:
            raise ValueError('Figure inventory SQL bytes changed during invocation')
    if inventory_physical_authority(entry['paths']) != entry['authority']:
        raise ValueError('Figure inventory source or helper changed during authentication')


def check_inventory_replay_cache(cache):
    for entry in cache.values():
        check_inventory_replay_entry(entry)


def verified_source_inventory(namespace_raw, wiki, date, dumpstatus_raw, paths, cache):
    """Parse once per invocation; reauthenticate all SQL before reusing its result."""
    if cache is None:
        return source_inventory(namespace_raw, wiki, date, dumpstatus_raw, paths)
    paths = tuple(sorted(Path(path).absolute() for path in paths))
    key = (namespace_raw, wiki, date, dumpstatus_raw, paths)
    if key in cache:
        entry = cache[key]
        check_inventory_replay_entry(entry)
        return decode(entry['value'])
    before = inventory_physical_authority(paths)
    value = source_inventory(namespace_raw, wiki, date, dumpstatus_raw, paths)
    if inventory_physical_authority(paths) != before:
        raise ValueError('Figure inventory authority changed during initial replay')
    sources = {row['path']: row for row in value['sources']}
    entry = {'paths': paths, 'authority': before, 'value': encoded(value),
             'identities': [{name: sources[str(path.resolve())][name]
                            for name in ('size', 'sha1', 'sha256')} for path in paths]}
    cache[key] = entry
    # The first caller owns the parsed value; only immutable bytes are cached.
    return value


def verify_inventory(value, namespace_raw, wiki, date, *, inventory_cache=None):
    if (not isinstance(value, dict) or value.get('schema') != INVENTORY_SCHEMA or
            not isinstance(value.get('sources'), list) or not isinstance(value.get('dumpstatus_raw'), str)):
        raise ValueError('Invalid Figure inventory authority')
    paths = []
    for row in value['sources']:
        if not isinstance(row, dict) or not isinstance(row.get('path'), str) or not Path(row['path']).is_absolute():
            raise ValueError('Invalid Figure inventory source locator')
        paths.append(Path(row['path']))
    expected = verified_source_inventory(namespace_raw, wiki, date, value['dumpstatus_raw'].encode(), paths, inventory_cache)
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
    default_pages = sum(row['state'] == 'tiff_default_page' for row in projection['records'])
    result = {'kind': 'file-logical-axes', 'file_inventory_complete': True,
            'whole_edition_occurrence_coverage': False, 'files': len(names), **counts,
            'eligible_occurrences': 'thumbnail with actual positive width <= source logical width and no height',
            'unsupported_occurrences': ['width-above-original', 'height-bound', 'framed', 'intrinsic',
                                        'unobserved-default-or-upright', 'missing-or-unsupported-file'],
            'inventory_sha256': digest(encoded(inventory))}
    observed = sum('observed_svg_width_px' in row for row in projection['records'])
    if default_pages:
        result['tiff_default_page_files'] = default_pages
        result['eligible_occurrences'] += '; or a separately proved TIFF default-first-page thumbnail without page/lossy options'
    if observed:
        result['observed_svg_files'] = observed
        result['eligible_occurrences'] += '; or the exact corroborated rasterized SVG width, without height'
        result['unsupported_occurrences'][0] = 'unobserved-width-above-original'
    heights = sum(len(row.get('observed_svg_heights', [])) for row in projection['records'])
    if heights:
        result['observed_svg_height_occurrences'] = heights
        result['parse_core_binding_proven'] = False
        result['eligible_occurrences'] += '; or the exact observed canonical SVG wiki/page/options/height context'
        result['unsupported_occurrences'][1] = 'unobserved-height-context'
    if query_titles is not None:
        result['provider'] = {'header_version': 2, 'rows': len(names),
            'positive_rows': counts['eligible'] + counts['unsupported'] + default_pages, 'negative_rows': counts['missing'],
            'sql_files': len(inventory['titles']), 'observed_query_files': len(query_titles),
            'observed_only_files': len(set(query_titles) - set(inventory['titles'])),
            'corpus_query_closure_proven': False}
    return result


MATERIALIZED_HTTP_MODE = 'materialized-http-origins-v1'


def materialized_http_origin_ids(plan):
    if not isinstance(plan, dict) or plan.get('metadata_mode') != MATERIALIZED_HTTP_MODE:
        raise ValueError('Contained Figure HTTP evidence requires its materialized plan mode')
    rows = plan.get('materialized_http_origins')
    if not isinstance(rows, list) or len(rows) > MAX_BATCHES:
        raise ValueError('Invalid materialized Figure origin declarations')
    identifiers = set()
    for row in rows:
        identifier = row.get('id') if isinstance(row, dict) else None
        if (not isinstance(identifier, str) or re.fullmatch(r'figure-origin-[0-9a-f]{64}', identifier) is None or
                identifier in identifiers):
            raise ValueError('Invalid or duplicate materialized Figure origin')
        identifiers.add(identifier)
    return identifiers


def terminal_http_origin(root, source, *, origin_plan=None):
    """Resolve one declared origin while preserving original HTTP leaf names."""
    root = Path(root)
    if origin_plan is None:
        origin_plan = inventory_document(root / PLAN) if (root / PLAN).exists() else {}
    if not isinstance(origin_plan, dict):
        raise ValueError('Invalid Figure capture plan')
    names = []
    for key in ('batch', 'tiff_batch'):
        value = source.get(key)
        if isinstance(value, dict):
            names.extend(value.values())
    for key in ('artifacts', 'tiff_artifacts'):
        value = source.get(key)
        if isinstance(value, list):
            names.extend(value)
    if not any(isinstance(name, str) and '/' in name for name in names):
        if origin_plan.get('metadata_mode') == MATERIALIZED_HTTP_MODE:
            raise ValueError('Materialized Figure HTTP evidence lacks its origin namespace')
        return root, source, ''
    identifiers = materialized_http_origin_ids(origin_plan)
    origin = None
    for name in names:
        if not isinstance(name, str) or len(parts := name.split('/')) != 2:
            raise ValueError('Figure HTTP evidence escapes one origin directory')
        if parts[0] not in identifiers or (origin is not None and parts[0] != origin):
            raise ValueError('Figure HTTP evidence uses an undeclared or mixed origin')
        metadata.safe_name(parts[1])
        origin = parts[0]
    local = root / origin
    complete_capture_directory_stamp(root)
    complete_capture_directory_stamp(local)
    if local.resolve() != root.resolve() / origin:
        raise ValueError('Figure HTTP origin resolves outside its capture')
    leaf = dict(source)
    for key in ('batch', 'tiff_batch'):
        if key in source:
            if not isinstance(source[key], dict) or set(source[key]) != {'request', 'accepted_receipt'}:
                raise ValueError('Invalid contained Figure HTTP batch')
            leaf[key] = {field: value.split('/')[1] for field, value in source[key].items()}
    for key in ('artifacts', 'tiff_artifacts'):
        if key in source:
            if not isinstance(source[key], list):
                raise ValueError('Invalid contained Figure HTTP artifact inventory')
            leaf[key] = [value.split('/')[1] for value in source[key]]
    return local, leaf, origin + '/'


def capture_member_paths(root, *, include_markers=False):
    """Enumerate regular files, plus only declared single-level origin directories."""
    root = Path(root)
    directories = {root: complete_capture_directory_stamp(root)}
    members, declared = {}, None
    for path in sorted(root.iterdir()):
        if not include_markers and path.name in (MANIFEST, COMPLETE):
            continue
        value = path.lstat()
        if stat.S_ISDIR(value.st_mode):
            if declared is None:
                if re.fullmatch(r'figure-origin-[0-9a-f]{64}', path.name) is None or not (root / PLAN).exists():
                    evidence.stamp(path)  # Preserve the legacy nonregular-member refusal.
                plan = inventory_document(root / PLAN)
                if not isinstance(plan, dict) or plan.get('metadata_mode') != MATERIALIZED_HTTP_MODE:
                    evidence.stamp(path)
                declared = materialized_http_origin_ids(plan)
            if path.name not in declared or path.resolve() != root.resolve() / path.name:
                raise ValueError('Unbound Figure capture directory')
            directories[path] = complete_capture_directory_stamp(path)
            for child in sorted(path.iterdir()):
                observed_artifact_name(child.name)
                evidence.stamp(child)
                members[path.name + '/' + child.name] = child
        else:
            evidence.stamp(path)
            members[path.name] = path
    if declared is not None and {path.name for path in directories if path != root} != declared:
        raise ValueError('Materialized Figure origin directory is missing')
    if any(complete_capture_directory_stamp(path) != before for path, before in directories.items()):
        raise ValueError('Figure capture membership changed during enumeration')
    return members, directories


def payload(root):
    result = {}
    members, directories = capture_member_paths(root)
    for name, path in members.items():
        identity = evidence.fingerprint(path)
        result[name] = {'bytes': identity['size'], 'sha256': identity['sha256']}
    if any(complete_capture_directory_stamp(path) != before for path, before in directories.items()):
        raise ValueError('Figure capture membership changed while hashing')
    return result


def replay(root, wiki, date, *, retained_cache=None, inventory_cache=None, regenerate_projection=None, _reprojection_records=None, _raw_index_out=None, _inventory_sources_out=None):
    """Replay original source captures, retaining their exact finite scope."""
    if _inventory_sources_out is not None and (type(_inventory_sources_out) is not dict or _inventory_sources_out):
        raise ValueError('Verified inventory source output must be an empty dictionary')
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
    if regenerate_projection is not None or _reprojection_records is not None:
        return replay_stream_capture(root, wiki, date, defaults, namespace, general,
            retained_cache=retained_cache, inventory_cache=inventory_cache,
            regenerate_projection=regenerate_projection, _reprojection_records=_reprojection_records,
            _raw_index_out=_raw_index_out, _inventory_sources_out=_inventory_sources_out)
    with (root / ROLES['figure-sizing']).open('rb') as source:
        first = source.readline(STREAM_HEADER_LIMIT + 1)
    try:
        stream_header = stream_decode(first) if len(first) <= STREAM_HEADER_LIMIT else None
    except (ValueError, UnicodeError):
        stream_header = None
    if isinstance(stream_header, dict) and stream_header.get('schema') == FILES_STREAM_SCHEMA:
        return replay_stream_capture(root, wiki, date, defaults, namespace, general,
            retained_cache=retained_cache, inventory_cache=inventory_cache,
            _raw_index_out=_raw_index_out, _inventory_sources_out=_inventory_sources_out)
    projection_raw = small(root / ROLES['figure-sizing'])
    projection = decode(projection_raw)
    file_level = isinstance(projection, dict) and projection.get('schema') == FILES_SCHEMA
    raw = small(root / ROLES['figure-sizing-raw'], MAX_METADATA if file_level else MAX_RESPONSE)
    site_raw = small(root / ROLES['figure-sizing-site'], MAX_RESPONSE)
    if file_level:
        if not figure_source_compatible(projection.get('core_revision'), general.get('git-hash')):
            raise ValueError('Figure defaults and file facts use different source versions')
        verify_figure_file_document(projection, raw, namespace, wiki, date, site_raw)
        inventory = verify_inventory(decode(small(root / INVENTORY)), namespace, wiki, date, inventory_cache=inventory_cache)
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


def _figure_capture_manifest(root, require_complete=True):
    manifest_raw = small(root / MANIFEST)
    manifest = decode(manifest_raw)
    if (not isinstance(manifest, dict) or manifest.get('schema') != SCHEMA or
            not isinstance(manifest.get('generator_sha256'), str) or
            re.fullmatch('[0-9a-f]{64}', manifest['generator_sha256']) is None):
        raise ValueError('Invalid Figure capture manifest')
    if require_complete and decode(small(root / COMPLETE)) != {
            'schema': SCHEMA, 'manifest_sha256': digest(manifest_raw)}:
        raise ValueError('Incomplete Figure capture')
    return manifest_raw, manifest


def _authenticate_figure_capture_files(root, manifest, inventory_cache):
    directory_stamp = complete_capture_directory_stamp(root)
    members, member_directories = capture_member_paths(root, include_markers=True)
    before = {path: evidence.stamp(path) for path in members.values()}
    artifacts = payload(root)
    if manifest.get('artifacts') != artifacts:
        raise ValueError('Figure capture differs from source replay')
    # Each output is already fully hashed in this invocation's payload. Bind
    # both manifest views to those bytes while the exact members stay unchanged.
    outputs = {role: artifacts[filename]['sha256'] for role, filename in output_roles(root).items()}
    if manifest.get('outputs') != outputs:
        raise ValueError('Figure capture differs from source replay')
    check_inventory_replay_cache(inventory_cache)
    after, after_directories = capture_member_paths(root, include_markers=True)
    if ({path: evidence.stamp(path) for path in after.values()} != before or
            after_directories != member_directories or
            complete_capture_directory_stamp(root) != directory_stamp):
        raise ValueError('Figure capture changed during content authentication')


def verify(root, require_complete=True, *, retained_cache=None, inventory_cache=None, regenerate_projection=None, _reprojection_records=None, _raw_index_out=None):
    if _raw_index_out is not None and (type(_raw_index_out) is not dict or _raw_index_out):
        raise ValueError('Verified raw index output must be an empty dictionary')
    inventory_cache = {} if inventory_cache is None else inventory_cache
    root = Path(root)
    if root.is_symlink() or not root.is_dir():
        raise ValueError('Unsafe Figure capture directory')
    if regenerate_projection is not None and (require_complete is not False or os.path.lexists(root / COMPLETE)):
        raise ValueError('Figure projection regeneration requires an incomplete capture')
    manifest_raw, manifest = _figure_capture_manifest(root, require_complete)
    generation = {} if regenerate_projection is None else {'regenerate_projection': regenerate_projection}
    if _reprojection_records is not None:
        if require_complete is not False or regenerate_projection is not None or type(_reprojection_records) is not _ReprojectionRecords:
            raise ValueError('Invalid private reprojection verification')
        generation['_reprojection_records'] = _reprojection_records
    # This private output carries only offsets from this verification. Publish
    # nothing to its caller until all semantic and content checks have passed.
    raw_index = {} if _raw_index_out is not None else None
    if raw_index is not None:
        generation['_raw_index_out'] = raw_index
    inventory_sources = {}
    defaults, coverage = replay(root, manifest.get('wiki'), manifest.get('date'), retained_cache=retained_cache, inventory_cache=inventory_cache,
                               _inventory_sources_out=inventory_sources, **generation)
    if coverage['kind'] == 'file-logical-axes':
        keys = ('wiki', 'date', 'name', 'url', 'size', 'sha1')
        if inventory_sources:
            path = root / INVENTORY
            if (path.resolve(), evidence.stamp(path)) != (inventory_sources['path'], inventory_sources['stamp']):
                raise ValueError('Figure inventory changed before source selection comparison')
            expected_sources = [dict(zip(keys, row, strict=True)) for row in inventory_sources['sources']]
        else:
            inventory = inventory_document(root / INVENTORY)
            expected_sources = [{key: row[key] for key in keys} for row in inventory['sources']]
        if manifest.get('capture_format') == FILES_STREAM_SCHEMA:
            for row in expected_sources:
                row['url'] = 'https://dumps.wikimedia.org'+row['url']
        if manifest.get('source_dump_files') != expected_sources:
            raise ValueError('Figure file source selection differs from the verified inventory')
    if (manifest.get('namespace_registry_sha256') != defaults['namespace_registry_sha256'] or
            manifest.get('coverage') != coverage):
        raise ValueError('Figure capture differs from source replay')
    _authenticate_figure_capture_files(root, manifest, inventory_cache)
    if regenerate_projection is not None and os.path.lexists(root / COMPLETE):
        raise ValueError('Figure capture completed during projection regeneration')
    if _raw_index_out is not None:
        _raw_index_out.update(raw_index)
    return manifest


def complete_capture(root, *, manifest_sha256, wiki, date):
    """Fully validate an owned unfinished stream, then publish only its marker."""
    if not isinstance(manifest_sha256, str) or re.fullmatch('[0-9a-f]{64}', manifest_sha256) is None:
        raise ValueError('Invalid incomplete Figure manifest identity')
    root = Path(root).absolute()
    if root.resolve() != root or root.is_symlink() or not root.is_dir():
        raise ValueError('Unsafe incomplete Figure capture directory')
    if root.lstat().st_uid != os.getuid():
        raise ValueError('Incomplete Figure capture is not owned')
    lock = root.with_name('.'+root.name+'.capture.lock')
    fd = os.open(lock, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    marker_fd = None
    retained_cache, inventory_cache = {}, {}
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.getuid():
            raise ValueError('Unsafe Figure capture lock')
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if os.path.lexists(root / COMPLETE):
            raise ValueError('Figure completion requires an incomplete capture')
        def output_state():
            members, directories = capture_member_paths(root, include_markers=True)
            return ({path: evidence.stamp(path) for path in members.values()},
                    {path: (*stamp, path.lstat().st_uid, path.lstat().st_gid)
                     for path, stamp in directories.items()})
        before = output_state()
        manifest_raw = small(root / MANIFEST)
        declared = decode(manifest_raw)
        if (digest(manifest_raw) != manifest_sha256 or not isinstance(declared, dict) or
                declared.get('wiki') != wiki or declared.get('date') != date or
                declared.get('capture_format') != FILES_STREAM_SCHEMA or
                set(declared.get('outputs', {})) != {*ROLES, 'file-metadata'}):
            raise ValueError('Incomplete Figure capture selection differs')
        if output_state() != before or os.path.lexists(root / COMPLETE):
            raise ValueError('Incomplete Figure capture changed before validation')
        verified = verify(root, require_complete=False,
                          retained_cache=retained_cache, inventory_cache=inventory_cache)
        check_prefix_cache(retained_cache)
        check_inventory_replay_cache(inventory_cache)
        if (verified != declared or small(root / MANIFEST) != manifest_raw or
                output_state() != before or os.path.lexists(root / COMPLETE)):
            raise ValueError('Incomplete Figure capture changed during validation')
        # No data or manifest is rewritten. Keep the newly created marker's FD
        # until terminal guards pass so failure removes only our own insertion.
        marker = encoded({'schema': SCHEMA, 'manifest_sha256': manifest_sha256})
        marker_fd = os.open(root / COMPLETE, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        pending = memoryview(marker)
        while pending:
            written = os.write(marker_fd, pending)
            if written <= 0:
                raise OSError('Incomplete Figure marker write')
            pending = pending[written:]
        def marker_identity():
            held = os.fstat(marker_fd)
            if (not stat.S_ISREG(held.st_mode) or held.st_nlink != 1 or
                    held.st_uid != os.getuid() or stat.S_IMODE(held.st_mode) != 0o600 or
                    held.st_size != len(marker)):
                raise ValueError('Figure completion marker identity changed')
            return (held.st_dev, held.st_ino, held.st_size, held.st_mtime_ns, held.st_ctime_ns)
        marker_before = marker_identity()
        os.fsync(marker_fd)
        if marker_identity() != marker_before or evidence.stamp(root / COMPLETE) != marker_before:
            raise ValueError('Figure completion marker identity changed')
        published = output_state()
        files_before, dirs_before = before
        files_after, dirs_after = published
        if (set(files_after) != set(files_before) | {root / COMPLETE} or
                any(files_after[path] != value for path, value in files_before.items()) or
                dirs_after.keys() != dirs_before.keys() or
                any((dirs_after[path][:3] + dirs_after[path][5:] != value[:3] + value[5:])
                    if path == root else dirs_after[path] != value
                    for path, value in dirs_before.items()) or
                small(root / MANIFEST) != manifest_raw or small(root / COMPLETE) != marker):
            raise ValueError('Incomplete Figure capture changed during completion publication')
        check_prefix_cache(retained_cache)
        check_inventory_replay_cache(inventory_cache)
        if (output_state() != published or marker_identity() != marker_before or
                evidence.stamp(root / COMPLETE) != marker_before):
            raise ValueError('Completed Figure capture changed before return')
        return verified
    except BaseException:
        if marker_fd is not None:
            held = os.fstat(marker_fd)
            try:
                current = (root / COMPLETE).lstat()
                if ((held.st_dev, held.st_ino) == (current.st_dev, current.st_ino) and
                        stat.S_ISREG(current.st_mode) and current.st_nlink == 1):
                    (root / COMPLETE).unlink()
            except FileNotFoundError:
                pass
        raise
    finally:
        retained_cache.clear()
        inventory_cache.clear()
        if marker_fd is not None:
            os.close(marker_fd)
        os.close(fd)


def validate_snapshot(path, wiki=None, date=None):
    path = Path(path)
    if path.name not in (*ROLES.values(), PROVIDER):
        raise ValueError('Unexpected Figure snapshot filename')
    manifest = verify(path.parent)
    if (wiki is not None and manifest['wiki'] != wiki) or (date is not None and manifest['date'] != date):
        raise ValueError('Figure capture edition/date mismatch')
    role = next(name for name, filename in output_roles(path.parent).items() if filename == path.name)
    return {**manifest, 'output_sha256': manifest['outputs'][role]}


def verify_tuple(paths, wiki=None, date=None, *, retained_cache=None, inventory_cache=None):
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
    def capture_identity():
        members, directories = capture_member_paths(root, include_markers=True)
        identities = {}
        for name, path in members.items():
            value = path.lstat()
            if not stat.S_ISREG(value.st_mode):
                raise ValueError('Figure source capture changed during validation')
            identities[name] = (str(path.resolve(strict=True)), value.st_dev, value.st_ino,
                value.st_mode, value.st_nlink, value.st_uid, value.st_gid, value.st_size,
                value.st_mtime_ns, value.st_ctime_ns)
        if any(complete_capture_directory_stamp(path) != before
               for path, before in directories.items()):
            raise ValueError('Figure source capture changed during validation')
        return identities, directories

    before = capture_identity()
    manifest_raw = small(root / MANIFEST)
    manifest = verify(root, retained_cache=retained_cache, inventory_cache=inventory_cache)
    if set(paths) != set(manifest['outputs']):
        raise ValueError('Shared file capture requires its Provider TSV and all four Figure roles')
    if (wiki is not None and manifest['wiki'] != wiki) or (date is not None and manifest['date'] != date):
        raise ValueError('Figure capture edition/date mismatch')
    # verify already authenticated every payload byte after semantic replay.
    # Reuse that result only while every exact member and directory stays fixed.
    marker_raw = encoded({'schema': SCHEMA, 'manifest_sha256': digest(manifest_raw)})
    if (small(root / MANIFEST) != manifest_raw or decode(manifest_raw) != manifest or
            small(root / COMPLETE) != marker_raw or capture_identity() != before):
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
    if (not isinstance(names, list) or not 1 <= len(names) <= 50 or
            any(not isinstance(name, str) or registry.file_title(name) != name for name in names) or
            len(set(names)) != len(names)):
        raise ValueError('Observed SVG request must name distinct canonical query keys')
    query = {'action': 'query', 'format': 'json', 'formatversion': '2',
             'meta': 'siteinfo', 'siprop': 'general|extensions', 'prop': 'imageinfo',
             'iiprop': 'size|sha1|timestamp|canonicaltitle|mediatype|mime|metadata|url',
             'iilimit': '1', 'redirects': '1', 'maxlag': '5', 'titles': '|'.join(names),
             'curtimestamp': '1', 'iiurlwidth': str(width)}
    request_query = request.get('query')
    if isinstance(request_query, dict) and request_query.get('iiprop') == query['iiprop'] + '|thumbmime':
        query['iiprop'] += '|thumbmime'
    url = request.get('url')
    if (request.get('fixed_verified_batch_contract') is not False or
            type(request.get('request_count')) is not int or request['request_count'] != 1 or
            request.get('query') != query or not isinstance(url, str) or len(url.encode('utf-8')) > metadata.MAX_URL):
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
    pages = {page['title']: page for page in data['query']['pages']}
    seen = set()
    for name in names:
        row = rows[name]
        if not row['exists']:
            raise ValueError('Observed SVG file is not positive')
        canonical = registry.file_title(row['canonicaltitle'])
        if canonical in seen:
            raise ValueError('Observed SVG request repeats a canonical file')
        seen.add(canonical)
        info = pages[row['response_title']]['imageinfo'][0]
        if observed_svg_width(info, info.get('mime'), row['mediatype'], row['width'], row['height']) != width:
            raise ValueError('Observed SVG request lacks exact rasterized width proof')
    return {'requests': names, 'response': raw.decode('utf-8'), 'observed_svg_width_px': width}


def retained_metadata_batch(path, wiki, date, namespace):
    """Reuse an existing request/receipt record; rederive facts from its raw API bytes."""
    path = Path(path)
    record = decode(small(path))
    if isinstance(record, dict) and ('jpeg_metadata_only' in record or record.get('schema') == 'wikidict.retained-jpeg-metadata-supplement.v1'):
        if (record.get('schema') != 'wikidict.retained-jpeg-metadata-supplement.v1' or
                record.get('jpeg_metadata_only') is not True or
                'observed_svg_width_px' in record or 'observed_svg_occurrences' in record):
            raise ValueError('Ambiguous retained JPEG supplemental authority')
    if isinstance(record, dict) and 'observed_svg_occurrences' in record:
        return retained_svg_occurrences(path, record, wiki, date, namespace)
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
    batch = {'requests': names, 'response': response.decode('utf-8')}
    if 'jpeg_metadata_only' in record:
        if (record.get('schema') != 'wikidict.retained-jpeg-metadata-supplement.v1' or
                record['jpeg_metadata_only'] is not True or 'observed_svg_width_px' in record):
            raise ValueError('Invalid explicit JPEG supplemental record')
        batch['jpeg_metadata_only'] = True
    return batch


def retained_svg_occurrences(path, record, wiki, date, namespace):
    """One shared identity batch plus unchanged parse artifacts in contained directories."""
    root = path.parent
    observations, artifacts = record.get('observed_svg_occurrences'), record.get('artifacts')
    if (root.is_symlink() or record.get('wiki') != wiki or record.get('date') != date or
            'observed_svg_width_px' in record or not isinstance(observations, list) or
            not 1 <= len(observations) <= 50 or not isinstance(artifacts, dict) or
            not 7 <= len(artifacts) <= 4+3*50):
        raise ValueError('Invalid retained SVG occurrence inventory')
    def member(name):
        if not isinstance(name, str):
            raise ValueError('Invalid SVG occurrence artifact path')
        parts = name.split('/')
        if not 1 <= len(parts) <= 2:
            raise ValueError('SVG occurrence artifact escapes its contained source')
        cursor = root
        for part in parts:
            observed_artifact_name(part);cursor = cursor/part
            if cursor.is_symlink():
                raise ValueError('SVG occurrence artifact is a symlink')
        return cursor
    for name, expected in artifacts.items():
        source = member(name)
        if (not isinstance(expected, dict) or set(expected) != {'size', 'sha256'} or
                type(expected.get('size')) is not int or not 0 <= expected['size'] <= MAX_RESPONSE):
            raise ValueError('Invalid SVG occurrence artifact identity')
        raw = small(source, MAX_RESPONSE)
        if len(raw) != expected['size'] or digest(raw) != expected['sha256']:
            raise ValueError('Retained SVG occurrence artifact changed')
    if metadata.NAMESPACE not in artifacts or small(root/metadata.NAMESPACE) != namespace:
        raise ValueError('SVG occurrence namespace differs')
    identity = record.get('batch')
    if (not isinstance(identity, dict) or set(identity) != {'request','accepted_receipt'} or
            any(not isinstance(name,str) or name not in artifacts for name in identity.values())):
        raise ValueError('Invalid retained SVG identity batch')
    if all('/' not in name and name.startswith(metadata.PREFIX) for name in identity.values()):
        names, raw = metadata.verified_batch(root, identity, wiki, artifacts, figure_axes=True)
        base_receipt = decode(small(root/identity['accepted_receipt']))
        response_name = metadata.safe_name(base_receipt['response'])
    else:
        request_path, receipt_path = (member(identity[key]) for key in ('request','accepted_receipt'))
        if request_path == receipt_path or request_path.parent != receipt_path.parent:
            raise ValueError('SVG identity request and receipt do not retain their original directory')
        request, receipt = decode(small(request_path,MAX_RESPONSE)), decode(small(receipt_path,MAX_RESPONSE))
        if (not isinstance(request,dict) or set(request) != {'controlled_render','historical_page_render',
                'input_data','query','request_count','url'} or request['controlled_render'] is not False or
                request['historical_page_render'] is not False or type(request['request_count']) is not int or request['request_count'] != 1):
            raise ValueError('Unreviewed retained SVG identity request profile')
        query = request['query']
        if not isinstance(query,dict) or not isinstance(query.get('titles'),str):
            raise ValueError('Missing SVG identity request titles')
        names = query['titles'].split('|')
        if (not 1 <= len(names) <= 50 or len(set(names)) != len(names) or
                query != metadata.query_for(wiki,names,figure_axes=True) or not isinstance(request['url'],str) or
                len(request['url'].encode()) > metadata.MAX_URL):
            raise ValueError('SVG identity request semantics changed')
        url = urlsplit(request['url'])
        if (url.fragment or url._replace(query='',fragment='').geturl() != wiktionary_api(wiki) or
                sorted(parse_qsl(url.query,keep_blank_values=True)) != sorted(query.items())):
            raise ValueError('SVG identity endpoint or encoded query differs')
        if (not isinstance(receipt,dict) or receipt.get('accepted') is not True or
                type(receipt.get('status')) is not int or receipt['status'] != 200 or
                type(receipt.get('request_count')) is not int or receipt['request_count'] != 1):
            raise ValueError('SVG identity receipt is not one accepted request')
        observed_artifact_name(receipt.get('response'))
        response_name = str((request_path.parent/receipt['response']).relative_to(root))
        if response_name not in artifacts:
            raise ValueError('SVG identity response is not retained')
        raw = small(member(response_name),MAX_RESPONSE)
        if type(receipt.get('response_bytes')) is not int or receipt['response_bytes'] != len(raw) or receipt.get('response_sha256') != digest(raw):
            raise ValueError('SVG identity receipt differs from its exact response')
    accounted = {metadata.NAMESPACE, *identity.values(), response_name}
    batch = {'requests': names, 'response': raw.decode(), 'observed_svg_occurrences': []}
    size = len(stream_encoded(batch))
    for item in observations:
        if not isinstance(item, dict) or set(item) != {'request', 'receipt', 'response'}:
            raise ValueError('Invalid retained SVG occurrence triple')
        if (any(not isinstance(name, str) for name in item.values()) or len(set(item.values())) != 3 or
                any(name not in artifacts or name in accounted for name in item.values())):
            raise ValueError('Missing or repeated SVG occurrence artifact')
        if len({str(member(name).parent) for name in item.values()}) != 1:
            raise ValueError('SVG occurrence triple does not retain one capture directory')
        observation = {key: small(member(name), MAX_RESPONSE).decode('utf-8') for key, name in item.items()}
        if decode(observation['receipt'].encode()).get('response') != Path(item['response']).name:
            raise ValueError('SVG occurrence receipt names a different response')
        size += len(stream_encoded(observation))-1+(1 if batch['observed_svg_occurrences'] else 0)
        if size > STREAM_RAW_LINE_LIMIT:
            raise ValueError('SVG occurrence aggregate exceeds its existing raw record bound')
        batch['observed_svg_occurrences'].append(observation)
        accounted.update(item.values())
    if accounted != set(artifacts):
        raise ValueError('Unaccounted retained SVG occurrence artifacts')
    plain = {'requests': names, 'response': raw.decode()}
    file_records((plain, batch), namespace, wiki, date, raw, has_batches=True,
                 record_limit=50, profile_kind=FIGURE_PROFILE_V4, allow_compatible_epochs=True)
    return batch


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


def replay_source(root, source, batch, wiki, date, namespace, http_files, prefix_cache=None, *, profile_kind=FIGURE_PROFILE_V3, inventory_cache=None, allow_compatible_epochs=False, origin_plan=None):
    if not isinstance(source, dict):
        raise ValueError('Invalid Figure request source')
    kind = source.get('kind')
    if kind in ('http-archived', 'http-archived-light', 'http-archived-lean'):
        local, leaf, prefix = terminal_http_origin(root, source, origin_plan=origin_plan)
        if prefix:
            directories = {Path(root): complete_capture_directory_stamp(Path(root)),
                           local: complete_capture_directory_stamp(local)}
            local_files = set()
            replay_source(local, leaf, batch, wiki, date, namespace, local_files, prefix_cache,
                profile_kind=profile_kind, inventory_cache=inventory_cache,
                allow_compatible_epochs=allow_compatible_epochs, origin_plan={})
            scoped = {prefix + name for name in local_files}
            if scoped & http_files:
                raise ValueError('Duplicate contained Figure HTTP evidence')
            if any(complete_capture_directory_stamp(path) != before for path, before in directories.items()):
                raise ValueError('Contained Figure HTTP directory changed during replay')
            http_files.update(scoped)
            return
    if kind == 'complete-stream':
        path = Path(source.get('path', ''))
        if not path.is_absolute() or path.resolve().is_relative_to(root.resolve()):
            raise ValueError('Complete Figure source aliases output')
        complete = read_complete_capture(path, prefix_cache, inventory_cache=inventory_cache, include_document=False)
        if (complete['manifest']['wiki'] != wiki or complete['manifest']['date'] != date or
                complete['namespace'] != namespace or complete_stream_batch(source, prefix_cache) != batch):
            raise ValueError('Retained complete Figure batch identity differs')
        return
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
    if kind == 'http-archived-lean':
        expected = {'kind', 'batch', 'artifacts'}
        if 'tiff_metadata_response' in batch:
            expected.update(('tiff_batch', 'tiff_artifacts'))
        if set(source) != expected:
            raise ValueError('Invalid lean Figure request evidence')
        base = {'requests': batch['requests'], 'response': batch['response']}
        replay_http_source(root, source, base, wiki, http_files, light=True)
        titles = lean_tiff_titles(base, namespace, wiki, date, profile_kind, allow_compatible_epochs=allow_compatible_epochs)
        if bool(titles) != ('tiff_metadata_response' in batch):
            raise ValueError('Archived lean Figure response lacks its required TIFF evidence')
        if titles:
            followup = {'kind': kind, 'batch': source['tiff_batch'], 'artifacts': source['tiff_artifacts']}
            replay_http_source(root, followup,
                {'requests': titles, 'response': batch['tiff_metadata_response']}, wiki, http_files,
                light=False, stage='tiff')
        # The exact base has already passed lean_tiff_titles above. A TIFF
        # companion still needs the complete identity/metadata join after its
        # HTTP proof; a plain base needs only its original exact-shape fence.
        if titles:
            file_records(iter((batch,)), namespace, wiki, date, batch['response'].encode(),
                         has_batches=True, record_limit=50, profile_kind=profile_kind,
                         allow_compatible_epochs=allow_compatible_epochs)
        elif set(batch) != {'requests', 'response'}:
            raise ValueError('Invalid Figure source batch')
        return
    if kind not in ('http-archived', 'http-archived-light') or set(source) != {'kind', 'batch', 'artifacts'}:
        raise ValueError('Invalid archived Figure HTTP source')
    light = kind == 'http-archived-light'
    replay_http_source(root, source, batch, wiki, http_files, light=light)
    if light:
        validate_metadata_light(batch, namespace, wiki, date)


def captured_http_stage(root, reference, wiki, *, light, stage=''):
    prefix = 'file-metadata.' + (stage+'-' if stage else '')
    match = re.fullmatch(re.escape(prefix)+r'response-(\d{6})-(\d{2})\.receipt\.json', reference['accepted_receipt'])
    if match is None or not 1 <= int(match[2]) <= 4 or reference['request'] != prefix+'request-'+match[1]+'.json':
        raise ValueError('Invalid captured Figure stage numbering')
    names = [reference['request']]
    for attempt in range(1, int(match[2])+1):
        stem = prefix+f'response-{match[1]}-{attempt:02d}'
        names.append(stem+'.receipt.json')
        if (root/(stem+'.raw.json')).exists():
            names.append(stem+'.raw.json')
    titles, raw = metadata.verified_batch(root, reference, wiki, set(names),
                                          figure_axes=True, figure_metadata_light=light)
    receipt = decode(small(root/reference['accepted_receipt']))
    accepted = root/metadata.safe_name(receipt['response'])
    names.remove(accepted.name)
    return titles, raw, names, (accepted, evidence.stamp(accepted))


def replay_http_source(root, source, batch, wiki, http_files, *, light, stage=''):
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
    prefix = 'file-metadata.' + (stage + '-' if stage else '')
    match = re.fullmatch(re.escape(prefix)+r'response-(\d{6})-(\d{2})\.receipt\.json', reference['accepted_receipt'])
    if match is None or not 1 <= int(match[2]) <= 4 or reference['request'] != f'{prefix}request-{match[1]}.json':
        raise ValueError('Invalid archived HTTP request numbering')
    allowed = {reference['request']}
    for attempt in range(1, int(match[2])+1):
        stem = f'{prefix}response-{match[1]}-{attempt:02d}'
        allowed.add(stem+'.receipt.json')
        failed_raw = root / (stem+'.raw.json')
        if attempt < int(match[2]) and failed_raw.exists():
            allowed.add(failed_raw.name)
    if set(names) != allowed:
        raise ValueError('Archived HTTP evidence has unrelated or incomplete files')
    response_name = metadata.safe_name(receipt.get('response'))
    if response_name != prefix+f'response-{match[1]}-{match[2]}.raw.json':
        raise ValueError('Archived response belongs to another request stage or attempt')
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



def record_http_archive(root, source, batch, archived, *, origin_plan=None):
    if source.get('kind') in ('http-archived', 'http-archived-light', 'http-archived-lean'):
        local, leaf, prefix = terminal_http_origin(root, source, origin_plan=origin_plan)
        if prefix:
            local_archived = {}
            record_http_archive(local, leaf, batch, local_archived, origin_plan={})
            for name, identity in local_archived.items():
                key = (name[0], prefix + name[1]) if isinstance(name, tuple) else prefix + name
                if key in archived:
                    raise ValueError('Duplicate contained Figure HTTP archive identity')
                archived[key] = identity
            return
        receipt = decode(small(root/source['batch']['accepted_receipt']))
        raw = batch['response'].encode('utf-8')
        archived[receipt['response']] = {'bytes': len(raw), 'sha256': digest(raw)}
        if 'tiff_metadata_response' in batch:
            receipt = decode(small(root/source['tiff_batch']['accepted_receipt']))
            raw = batch['tiff_metadata_response'].encode('utf-8')
            archived[receipt['response']] = {'bytes': len(raw), 'sha256': digest(raw)}
            request = decode(small(root/source['tiff_batch']['request']))
            base_receipt = decode(small(root/source['batch']['accepted_receipt']))
            archived[('tiff-titles', base_receipt['response'])] = request['titles']


def replay_stream_capture(root, wiki, date, defaults, namespace, general, *, retained_cache=None, inventory_cache=None, regenerate_projection=None, _reprojection_records=None, _raw_index_out=None, _inventory_sources_out=None):
    if _inventory_sources_out is not None and (type(_inventory_sources_out) is not dict or _inventory_sources_out):
        raise ValueError('Verified inventory source output must be an empty dictionary')
    if _raw_index_out is not None and (type(_raw_index_out) is not dict or _raw_index_out):
        raise ValueError('Verified raw index output must be an empty dictionary')
    site_raw = small(root / ROLES['figure-sizing-site'], MAX_RESPONSE)
    raw_path = root / ROLES['figure-sizing-raw']
    def raw_identity():
        return (raw_path.resolve(), evidence.stamp(raw_path), complete_capture_directory_stamp(root))
    raw_before = raw_identity()
    generation = {} if regenerate_projection is None else {'regenerate_projection': regenerate_projection}
    if _reprojection_records is not None:
        generation['_reprojection_records'] = _reprojection_records
    projection = verify_stream_document(root / ROLES['figure-sizing'], raw_path,
                                        namespace, wiki, date, site_raw, **generation)
    if regenerate_projection is not None:
        # The verifier fences the single owned projection insertion. Preserve
        # the unchanged raw identity and use the resulting directory identity.
        after_generation = raw_identity()
        if (after_generation[:2] != raw_before[:2] or
                after_generation[2][:3] != raw_before[2][:3]):
            raise ValueError('Figure raw identity changed during projection generation')
        if os.path.lexists(root / COMPLETE):
            raise ValueError('Figure capture completed during projection regeneration')
        raw_before = after_generation
    if raw_identity() != raw_before:
        raise ValueError('Figure raw identity changed during projection verification')
    # These are exactly the reducer options used by verify_stream_document.
    # The surrounding closure fixes namespace, wiki and date for both calls.
    verified_options = dict(has_batches=bool(projection['base_batches']), record_limit=projection['records_count'],
        profile_kind=projection['source_profile']['kind'] if projection['source_profile'] is not None else FIGURE_PROFILE_V3,
        allow_tiff_companion=replay_contract(projection) or projection['generator_sha256'] == LEGACY_TIFF_GENERATOR,
        allow_compatible_epochs=projection.get('replay_contract') in (REPLAY_CONTRACT_V3, REPLAY_CONTRACT_V4, REPLAY_CONTRACT),
        allow_decimal_tiff_axes=projection.get('replay_contract') in (REPLAY_CONTRACT_V4, REPLAY_CONTRACT),
        allow_default_tiff_page=projection.get('replay_contract') == REPLAY_CONTRACT)
    verified_count = len(projection['records'])
    def root_record_count(site, **options):
        # Only this invocation's exact whole-stream semantic result may replace
        # the identical root-origin replay. No decoded response is retained.
        if site != site_raw or options != verified_options:
            return None
        if raw_identity() != raw_before:
            raise ValueError('Figure raw identity changed before root semantic reuse')
        return verified_count
    if not figure_source_compatible(projection['core_revision'], general.get('git-hash')):
        raise ValueError('Figure defaults and streamed facts use different source versions')
    inventory_path = root / INVENTORY
    inventory_before = ((inventory_path.resolve(), evidence.stamp(inventory_path))
                        if _inventory_sources_out is not None else None)
    inventory = verify_inventory(inventory_document(inventory_path), namespace, wiki, date, inventory_cache=inventory_cache)
    query_inputs = decode(small(root / QUERY_INPUTS))
    query_titles = provider_query_titles(root, query_inputs, namespace, wiki, date)
    coverage = file_coverage(projection, inventory, query_titles)
    verify_provider_stream(root / PROVIDER, projection)
    # All record consumers have finished. Keep only header/scalar authority
    # while replaying nested parents; their records must not overlap this graph.
    del projection['records']
    http_files, prefix_cache = set(), {} if retained_cache is None else retained_cache
    archived, planned = {}, []
    plan = inventory_document(root / PLAN)
    if ((projection.get('replay_contract') in (REPLAY_CONTRACT_V3, REPLAY_CONTRACT_V4, REPLAY_CONTRACT)) !=
            (plan.get('replay_contract') in (REPLAY_CONTRACT_V3, REPLAY_CONTRACT_V4, REPLAY_CONTRACT)) or
            (projection.get('replay_contract') in (REPLAY_CONTRACT_V4, REPLAY_CONTRACT)) !=
            (plan.get('replay_contract') in (REPLAY_CONTRACT_V4, REPLAY_CONTRACT)) or
            (projection.get('replay_contract') == REPLAY_CONTRACT) !=
            (plan.get('replay_contract') == REPLAY_CONTRACT)):
        raise ValueError('Figure response epoch contract differs from capture plan')
    mode = plan.get('metadata_mode', 'full')
    if mode not in ('full', 'lean-tiff-v1', MATERIALIZED_HTTP_MODE):
        raise ValueError('Invalid archived Figure metadata mode')
    materialized = (materialized_origin_catalog(root,plan,wiki,date,namespace,inventory) if mode==MATERIALIZED_HTTP_MODE else None)
    selected_profile = plan.get('figure_profile', FIGURE_PROFILE_V3)
    prefix_sources, light_requests, ordinary_requests, lean_requests = [], set(), set(), set()
    complete_sources = []
    offsets = [] if materialized is not None or _raw_index_out is not None else None
    replay_identity = {} if offsets is not None else None
    batches = stream_values(raw_path, RAW_STREAM_SCHEMA, identity_out=replay_identity, record_offsets=offsets)
    header = next(batches)
    sources = source_records(root / FILE_REQUESTS, header['base_batches']+header['observed_batches'])
    def selected_batches(selected):
        # The two complete traversals have validated every physical record.
        # Retain only offsets and digests, and replay each origin's own rows.
        if offsets is None or len(offsets) != header['base_batches']+header['observed_batches']:
            raise ValueError('Incomplete Figure raw index')
        if raw_identity() != raw_before:
            raise ValueError('Figure raw identity changed before selected replay')
        encoding = raw_record_encoding(header)
        with raw_path.open('rb') as source:
            def held_stamp():
                value = os.fstat(source.fileno())
                if not stat.S_ISREG(value.st_mode):
                    raise ValueError('Figure indexed raw source changed')
                return (value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_ctime_ns)
            if held_stamp() != raw_before[1]:
                raise ValueError('Figure indexed raw source changed')
            for number in sorted(selected):
                if type(number) is not int or not 0 <= number < len(offsets):
                    raise ValueError('Invalid Figure selected raw index')
                offset, size, sha = offsets[number]
                source.seek(offset)
                raw = source.read(size)
                if len(raw) != size or digest(raw) != sha:
                    raise ValueError('Figure indexed raw record changed')
                yield raw_record_decode(raw, encoding)
            if held_stamp() != raw_before[1] or raw_identity() != raw_before:
                raise ValueError('Figure raw identity changed during selected replay')
    for batch, source in zip(batches, sources, strict=True):
        replay_source(root, source, batch, wiki, date, namespace, http_files, prefix_cache, profile_kind=selected_profile, inventory_cache=inventory_cache,
                      allow_compatible_epochs=projection.get('replay_contract') in (REPLAY_CONTRACT_V3, REPLAY_CONTRACT_V4, REPLAY_CONTRACT), origin_plan=plan)
        record_http_archive(root, source, batch, archived, origin_plan=plan)
        if materialized is not None:materialized_frame_echo(materialized,source,batch,archived,root)
        if source['kind'] in ('http-archived', 'http-archived-light', 'http-archived-lean'):
            planned.append(batch['requests'])
        if source['kind'] == 'closed-prefix':
            prefix_sources.append(source)
        elif source['kind'] == 'complete-stream':
            complete_sources.append(source)
        elif source['kind'] == 'http-archived-light':
            light_requests.update(batch['requests'])
        elif source['kind'] == 'http-archived':
            ordinary_requests.update(batch['requests'])
        elif source['kind'] == 'http-archived-lean':
            lean_requests.update(batch['requests'])
    check_prefix_cache(prefix_cache)
    if (('max_inflight' in plan and (plan['max_inflight'] != 2 or type(plan['max_inflight']) is not int)) or
            (('max_inflight' in plan or mode == 'lean-tiff-v1') and
             digest(encoded(planned)) != plan['planned_requests_sha256'])):
        raise ValueError('Figure occupied-slot request plan differs from ordered replay')
    if (plan.get('wiki') != wiki or plan.get('date') != date or
            plan.get('inventory_sha256') != digest(encoded(inventory)) or
            plan.get('namespace_registry_sha256') != digest(namespace) or
            plan.get('records_count') != header['records_count']):
        raise ValueError('Figure stream differs from its selected capture plan')
    selected_profile = plan.get('figure_profile', FIGURE_PROFILE_V3)
    if (selected_profile not in (FIGURE_PROFILE_V3, FIGURE_PROFILE_V4, FIGURE_PROFILE_V5) or
            (projection['source_profile'] is not None and
             projection['source_profile']['kind'] != selected_profile)):
        raise ValueError('Figure source profile differs from its selected capture plan')
    complete_refs = plan.get('complete_captures', [])
    if not isinstance(complete_refs, list) or len(complete_refs) > 1:
        raise ValueError('Invalid complete Figure source selection')
    required_complete = []
    for reference in complete_refs:
        if (not isinstance(reference, dict) or set(reference) != {'kind', 'path', 'sha256'} or
                reference['kind'] != 'complete-stream'):
            raise ValueError('Invalid complete Figure source reference')
        complete = read_complete_capture(Path(reference['path']), prefix_cache, inventory_cache=inventory_cache, include_document=False)
        if (complete['manifest_sha256'] != reference['sha256'] or
                complete['inventory'] != inventory or
                query_inputs[:len(complete['query_inputs'])] != complete['query_inputs'] or
                complete['defaults'] != plan.get('defaults')):
            raise ValueError('Complete Figure input selection differs')
        required_complete.extend(dict(reference, batch=i) for i in range(len(complete['offsets'])))
    if complete_sources != required_complete:
        raise ValueError('Complete Figure source is omitted, duplicated, or out of order')
    prefixes = plan.get('closed_prefixes', [])
    if not isinstance(prefixes, list) or len(prefixes) > 1:
        raise ValueError('Invalid closed Figure transition selection')
    required_sources, required_light = [], set()
    for reference in prefixes:
        if (not isinstance(reference, dict) or set(reference) != {'kind', 'path', 'sha256'} or
                reference['kind'] != 'closed-prefix' or digest(small(Path(reference['path']))) != reference['sha256']):
            raise ValueError('Closed Figure transition authority changed')
        prefix = read_closed_prefix(Path(reference['path']), prefix_cache)
        required_sources.extend(dict(reference, batch=i) for i in range(prefix['batch_count']))
        required_light.update(prefix['light_titles'])
    if (prefix_sources != required_sources or
            (mode == 'full' and (light_requests != required_light or required_light & ordinary_requests or lean_requests)) or
            (mode == 'lean-tiff-v1' and (light_requests or ordinary_requests)) or
            plan.get('metadata_light_titles', []) != sorted(required_light, key=lambda t:t.encode())):
        raise ValueError('Archived metadata-light scope differs from its closed transition')
    expected = {*defaults['artifacts'], site_info.MANIFEST, site_info.COMPLETE, *ROLES.values(),
                INVENTORY, FILE_REQUESTS, QUERY_INPUTS, PROVIDER, PLAN, *http_files,
                *(row['path'] for row in query_inputs)}
    if materialized is not None:
        if replay_identity != {'size': projection['raw_bytes'], 'sha256': projection['raw_sha256']}:
            raise ValueError('Figure indexed replay lacks its completed stream identity')
        expected.update(validate_materialized_echo(materialized,plan,wiki,date,namespace,
                                                    root_record_count=root_record_count, verified_batches=selected_batches))
        if raw_identity() != raw_before:
            raise ValueError('Figure raw identity changed after root semantic reuse')
    manifest = decode(small(root / MANIFEST))
    if manifest.get('capture_format') != FILES_STREAM_SCHEMA:
        raise ValueError('Figure stream manifest format differs')
    resumes = manifest.get('resumes', [])
    if materialized is not None and resumes:
        raise ValueError('Materialized Figure plan cannot resume an original acquisition')
    if not isinstance(resumes, list) or any(not isinstance(row, dict) for row in resumes) or len({row.get('path') for row in resumes}) != len(resumes):
        raise ValueError('Invalid Figure resume history')
    for reference in resumes:
        proof = read_resume(root, reference, plan, live=False, planned=planned, archived=archived)
        expected.update((reference['path'], proof['failure']['path']))
    members,_ = capture_member_paths(root)
    if set(members) != expected:
        raise ValueError('Unexpected or incomplete streamed Figure evidence')
    if _inventory_sources_out is not None:
        if (inventory_path.resolve(), evidence.stamp(inventory_path)) != inventory_before:
            raise ValueError('Figure inventory changed during source replay')
        # Only source scalars cross this call; the full inventory dies with replay.
        sources = tuple(tuple(row[key] for key in ('wiki', 'date', 'name', 'url', 'size', 'sha1'))
                        for row in inventory['sources'])
    if _raw_index_out is not None:
        if (len(offsets) != header['base_batches'] + header['observed_batches'] or
                replay_identity != {'size': projection['raw_bytes'], 'sha256': projection['raw_sha256']} or
                raw_identity() != raw_before):
            raise ValueError('Verified raw index differs from its completed stream')
        encoding = raw_record_encoding(header, allow_encoded=projection.get('replay_contract') in
            (REPLAY_CONTRACT_V2, REPLAY_CONTRACT_V3, REPLAY_CONTRACT_V4, REPLAY_CONTRACT))
        _raw_index_out.update(header=header, offsets=offsets, encoding=encoding,
                              identity=replay_identity, stamp=raw_before[1])
    if _inventory_sources_out is not None:
        _inventory_sources_out.update(path=inventory_before[0], stamp=inventory_before[1], sources=sources)
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


def pending_http_records(root, plan, failure, planned, *, archived=None, closed_oversize=None, allow_compatible_epochs=False):
    if plan.get('metadata_mode') != 'lean-tiff-v1':
        return legacy_pending_http_records(root, plan, failure, planned,
            archived=archived, closed_oversize=closed_oversize)
    if closed_oversize is not None:
        raise ValueError('Lean TIFF capture cannot reinterpret an oversized response')
    numbers = failure.get('pending_http', [])
    first = max(0, min(failure['committed_batches']-len(plan['retained']),
                      plan['base_batches']-len(plan['retained'])))+1
    slots = plan.get('max_inflight', 1)
    files = failure['artifacts']
    actual = {int(match[1]) for name in files if (match := re.fullmatch(
        r'file-metadata\.(?:tiff-)?(?:request|response)-(\d{6})(?:-\d{2})?\.(?:json|raw\.json|receipt\.json)', name))
        and int(match[1]) >= first}
    if (slots not in (1, 2) or type(slots) is not int or not isinstance(numbers, list) or
            any(type(n) is not int for n in numbers) or numbers != sorted(set(numbers)) or
            set(numbers) != actual or not set(numbers) <= set(range(first, first+slots)) or
            planned is None or digest(encoded(planned)) != plan['planned_requests_sha256'] or
            any(n > len(planned) for n in numbers)):
        raise ValueError('Invalid lean Figure pending request plan')
    namespace = small(root / (site_info.PREFIX+'namespace-registry.tsv'))
    result = {}
    for number in numbers:
        state = pending_http_stage(root, number, planned[number-1], plan['wiki'], files,
                                   light=True, archived=archived)
        tiff_files = {name for name in files if name.startswith(f'file-metadata.tiff-request-{number:06d}.') or
                      name.startswith(f'file-metadata.tiff-response-{number:06d}-')}
        if state['accepted'] is not None:
            receipt = decode(small(root/state['accepted']['accepted_receipt']))
            batch = None
            if (root/receipt['response']).exists():
                names, response = metadata.verified_batch(root, state['accepted'], plan['wiki'], set(files),
                                                           figure_axes=True, figure_metadata_light=True)
                batch = {'requests': names, 'response': response.decode('utf-8')}
                titles = lean_tiff_titles(batch, namespace, plan['wiki'], plan['date'],
                                         plan.get('figure_profile', FIGURE_PROFILE_V3), allow_compatible_epochs=allow_compatible_epochs)
            else:
                titles = archived.get(('tiff-titles', receipt['response']), [])
            if tiff_files:
                if not titles:
                    raise ValueError('Unexpected pending TIFF response')
                followup = pending_http_stage(root, number, titles, plan['wiki'], files,
                                              light=False, stage='tiff', archived=archived)
                state['tiff'] = followup
                state['artifacts'].update(followup['artifacts'])
                if followup['accepted'] is not None and batch is not None:
                    receipt = decode(small(root/followup['accepted']['accepted_receipt']))
                    if (root/receipt['response']).exists():
                        _, raw = metadata.verified_batch(root, followup['accepted'], plan['wiki'], set(files), figure_axes=True)
                        batch['tiff_metadata_response'] = raw.decode('utf-8')
                        validate_lean_batch(batch, namespace, plan['wiki'], plan['date'],
                                            plan.get('figure_profile', FIGURE_PROFILE_V3), allow_compatible_epochs=allow_compatible_epochs)
        elif tiff_files:
            raise ValueError('TIFF request precedes accepted lean identity')
        result[number] = state
    return result


def pending_http_stage(root, number, titles, wiki, files, *, light, stage='', archived=None):
    prefix = 'file-metadata.' + (stage+'-' if stage else '')
    name = f'{prefix}request-{number:06d}.json'
    if name not in files or decode(small(root/name)) != {
            'titles': titles, 'query': metadata.query_for(wiki, titles, figure_axes=True, figure_metadata_light=light),
            'url': metadata.query_url(wiki, titles, figure_axes=True, figure_metadata_light=light)}:
        raise ValueError('Pending Figure stage differs from its exact planned request')
    receipts = sorted(n for n in files if re.fullmatch(
        re.escape(prefix)+rf'response-{number:06d}-\d{{2}}\.receipt\.json', n))
    if len(receipts) > 4:
        raise ValueError('Pending Figure stage exceeds four attempts')
    accepted, accounted = None, {name}
    for attempt, receipt_name in enumerate(receipts, 1):
        stem = f'{prefix}response-{number:06d}-{attempt:02d}'
        if receipt_name != stem+'.receipt.json' or accepted is not None:
            raise ValueError('Pending Figure stage attempt numbering changed')
        receipt = decode(small(root/receipt_name));accounted.add(receipt_name)
        if receipt.get('request') != name:
            raise ValueError('Pending Figure stage receipt belongs to another request')
        response = receipt.get('response')
        if response is not None:
            if response != stem+'.raw.json' or files.get(response) != {
                    'bytes': receipt.get('response_bytes'), 'sha256': receipt.get('response_sha256')}:
                raise ValueError('Pending Figure stage response identity changed')
            accounted.add(response)
        if receipt.get('accepted') is True:
            if attempt != len(receipts) or receipt.get('status') != 200 or response is None:
                raise ValueError('Invalid accepted pending Figure stage')
            accepted = {'request': name, 'accepted_receipt': receipt_name}
            if (root/response).exists():
                metadata.verified_batch(root, accepted, wiki, set(files),
                                        figure_axes=True, figure_metadata_light=light)
            elif archived is None or archived.get(response) != files[response]:
                raise ValueError('Pending Figure stage was not archived exactly')
        elif (receipt.get('accepted') is not False or receipt.get('status') is not None or
                receipt.get('api_error_code') is not None or response is not None):
            raise ValueError('Rejected Figure stage cannot authorize a retry')
    if accepted is None and len(receipts) == 4:
        raise ValueError('Pending Figure stage exhausted its four attempts')
    actual = {n for n in files if n == name or n.startswith(f'{prefix}response-{number:06d}-')}
    if actual != accounted:
        raise ValueError('Unaccounted pending Figure stage artifact')
    return {'accepted': accepted, 'first_attempt': len(receipts)+1, 'artifacts': accounted}


def legacy_pending_http_records(root, plan, failure, planned, *, archived=None, closed_oversize=None):
    """Authenticate the pending head and at most one lookahead, without HTTP."""
    numbers = failure.get('pending_http', [])
    if not isinstance(numbers, list) or any(type(number) is not int for number in numbers):
        raise ValueError('Invalid pending Figure request inventory')
    first = max(0, min(failure['committed_batches']-len(plan['retained']),
                      plan['base_batches']-len(plan['retained'])))+1
    actual = {int(match[1]) for name in failure['artifacts']
              if (match := re.fullmatch(r'file-metadata\.(?:request|response)-(\d{6})(?:-\d{2})?\.(?:json|raw\.json|receipt\.json)', name))
              and int(match[1]) >= first}
    if plan.get('max_inflight') == 2 and set(numbers) != actual:
        raise ValueError('Unrecorded pending Figure request artifacts')
    if not numbers:
        return {}
    if (plan.get('max_inflight') != 2 or not isinstance(numbers, list) or
            any(type(number) is not int for number in numbers) or numbers != sorted(set(numbers)) or
            planned is None or digest(encoded(planned)) != plan['planned_requests_sha256']):
        raise ValueError('Invalid pending Figure request plan')
    if not set(numbers) <= {first, first+1} or any(number > len(planned) for number in numbers):
        raise ValueError('Figure pending requests exceed the two occupied slots')
    namespace = small(root / (site_info.PREFIX+'namespace-registry.tsv'))
    registry = evidence.Registry(namespace, plan['wiki'], plan['date'])
    files, result = failure['artifacts'], {}
    oversize_authenticated = False
    if closed_oversize is not None and failure.get('error') != 'Oversized API response':
        raise ValueError('Pending oversize evidence requires its closed failure')
    for number in numbers:
        name = f'file-metadata.request-{number:06d}.json'
        titles = planned[number-1]
        light = set(titles) <= set(plan.get('metadata_light_titles', []))
        if name not in files or decode(small(root/name)) != {
                'titles': titles, 'query': metadata.query_for(plan['wiki'], titles, figure_axes=True, figure_metadata_light=light),
                'url': metadata.query_url(plan['wiki'], titles, figure_axes=True, figure_metadata_light=light)}:
            raise ValueError('Pending Figure request differs from its planned identity')
        receipts = sorted(name for name in files if re.fullmatch(
            rf'file-metadata\.response-{number:06d}-\d{{2}}\.receipt\.json', name))
        if not 0 <= len(receipts) <= 4:
            raise ValueError('Pending Figure request has no complete bounded attempt evidence')
        accepted, terminal_oversize = None, False
        accounted = {name}
        for attempt, receipt_name in enumerate(receipts, 1):
            stem = f'file-metadata.response-{number:06d}-{attempt:02d}'
            if receipt_name != stem+'.receipt.json' or accepted is not None:
                raise ValueError('Pending Figure attempt numbering changed')
            receipt = decode(small(root/receipt_name))
            accounted.add(receipt_name)
            if receipt.get('request') != name:
                raise ValueError('Pending Figure receipt belongs to another request')
            response = receipt.get('response')
            if response is not None:
                expected = {'bytes': receipt.get('response_bytes'), 'sha256': receipt.get('response_sha256')}
                if response != stem+'.raw.json' or files.get(response) != expected:
                    raise ValueError('Pending Figure response identity changed')
                accounted.add(response)
            if receipt.get('accepted') is True:
                if attempt != len(receipts) or receipt.get('status') != 200 or response is None:
                    raise ValueError('Invalid accepted pending Figure response')
                accepted = {'request': name, 'accepted_receipt': receipt_name}
                if (root/response).exists():
                    names, raw = metadata.verified_batch(root, accepted, plan['wiki'], set(files),
                        figure_axes=True, figure_metadata_light=light)
                    metadata.classify_response(decode(raw), names, registry)
                elif archived is None or archived.get(response) != files[response]:
                    raise ValueError('Pending accepted response was not archived exactly')
            elif (closed_oversize is not None and number == first and
                    receipt_name == closed_oversize[0] and receipt == closed_oversize[1]):
                # The caller authenticated this exact terminal response against
                # the closed failure. It is evidence, never retry permission.
                if (attempt != len(receipts) or receipt.get('status') != 200 or
                        receipt.get('accepted') is not False or receipt.get('api_error_code') is not None or
                        receipt.get('error') != 'Oversized API response' or response is None or
                        receipt.get('response_bytes') != MAX_RESPONSE + 1):
                    raise ValueError('Invalid closed pending oversize evidence')
                terminal_oversize = oversize_authenticated = True
            elif (receipt.get('accepted') is not False or receipt.get('status') is not None or
                    receipt.get('api_error_code') is not None or response is not None):
                raise ValueError('Rejected API observation cannot become pending retry permission')
        if accepted is None and len(receipts) == 4 and not terminal_oversize:
            raise ValueError('Pending Figure request exhausted its four attempts')
        actual_files = {name for name in files if name == f'file-metadata.request-{number:06d}.json' or
                        name.startswith(f'file-metadata.response-{number:06d}-')}
        if actual_files != accounted:
            raise ValueError('Unaccounted pending Figure attempt artifact')
        result[number] = {'accepted': accepted, 'first_attempt': len(receipts)+1, 'artifacts': accounted}
    if closed_oversize is not None and not oversize_authenticated:
        raise ValueError('Declared pending oversize response was not authenticated')
    return result


def read_resume(root, reference, plan, *, live, planned=None, archived=None):
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
            not 0 <= failure['committed_batches'] < plan['base_batches']+plan['observed_batches'] or
            (failure['committed_batches'] == 0 and plan.get('metadata_mode') != 'lean-tiff-v1')):
        raise ValueError('Figure checkpoint is not an authenticated closed wall-stop prefix')
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
        elif (not live and archived is not None and not (root/name).exists() and
                name.startswith(('file-metadata.response-', 'file-metadata.tiff-response-')) and name.endswith('.raw.json') and
                archived.get(name) == descriptor):
            pass
        elif evidence.fingerprint(root / name)['sha256'] != descriptor['sha256'] or evidence.stamp(root / name)[2] != descriptor['bytes']:
            raise ValueError('Figure checkpoint evidence changed')
        if name.endswith('.receipt.json') and name.startswith(('file-metadata.response-', 'file-metadata.tiff-response-')):
            receipt = decode(small(root / name))
            if receipt.get('accepted') is not True and (receipt.get('status') is not None or receipt.get('api_error_code') is not None):
                raise ValueError('Rejected API observation requires separate scope review')
    if live and set(payload(root)) != {*files, failure_ref['path'], reference['path']}:
        raise ValueError('Figure checkpoint has uncommitted artifacts')
    proof['_pending_http'] = pending_http_records(root, plan, failure, planned, archived=archived,
        allow_compatible_epochs=plan.get('replay_contract') in (REPLAY_CONTRACT_V3, REPLAY_CONTRACT_V4, REPLAY_CONTRACT))
    if failure['committed_batches'] == 0 and proof['_pending_http'].get(1, {}).get('accepted') is None:
        raise ValueError('Empty lean prefix lacks its accepted first response')
    proof['_failure'] = failure
    return proof


CLOSED_PREFIX_SCHEMA = 'wikidict.figure-closed-oversize-prefix.v1'
SOURCE_PREFIX_SCHEMA = 'wikidict.figure-closed-source-prefix.v1'
CLOSED_PREFIX_SCHEMAS = (CLOSED_PREFIX_SCHEMA, SOURCE_PREFIX_SCHEMA)


def complete_capture_directory_stamp(root):
    value = root.lstat()
    if not stat.S_ISDIR(value.st_mode):
        raise ValueError('Complete Figure source directory changed')
    return (value.st_dev, value.st_ino, value.st_mode, value.st_mtime_ns, value.st_ctime_ns)


def read_complete_capture(path, cache=None, *, inventory_cache=None, include_document=True):
    """Replay a published stream; selection callers may also request its facts."""
    if type(include_document) is not bool:
        raise ValueError('Invalid complete Figure document selection')
    path = Path(path)
    if (not path.is_absolute() or path.resolve() != path or path.name != MANIFEST or
            path.is_symlink() or path.parent.is_symlink()):
        raise ValueError('Unsafe complete Figure manifest locator')
    cache = {} if cache is None else cache
    key = ('complete-stream', str(path))
    if key in cache:
        value = cache[key]
        if value is None:
            raise ValueError('Cyclic complete Figure source')
        # The first replay and final check cover every parent member. Between
        # batches guard the directory and the exact authorities consumed here.
        selected = (path, value['root'] / COMPLETE, value['raw_path'])
        if (complete_capture_directory_stamp(value['root']) != value['directory_stamp'] or
                any(complete_capture_directory_stamp(p) != before
                    for p, before in value.get('member_directories', {}).items()) or
                any(evidence.stamp(p) != value['stamps'][p] for p in selected)):
            raise ValueError('Complete Figure source changed')
        if include_document and 'document' not in value:
            # A validation-only reader may have populated this invocation's
            # cache first. Materialize selection facts only under the same full
            # member/context fences and the already verified projection bytes.
            try:
                check_prefix_cache(cache)
                # Selection can follow a validation-only call made without a
                # shared SQL proof. Use the ordinary inventory validator here:
                # it replays cold when absent and guards matching local proof.
                selection_inventory = {} if inventory_cache is None else inventory_cache
                verify_inventory(value['inventory'], value['namespace'],
                                 value['manifest']['wiki'], value['manifest']['date'],
                                 inventory_cache=selection_inventory)
                identity = {}
                values = stream_values(value['root'] / ROLES['figure-sizing'], FILES_STREAM_SCHEMA,
                                       identity_out=identity)
                try:
                    header = next(values)
                    document = dict(header, records=list(values))
                finally:
                    values.close()
                if (header != value['projection_header'] or
                        identity != {'size': value['stamps'][value['root'] / ROLES['figure-sizing']][2],
                                     'sha256': value['manifest']['outputs']['figure-sizing']}):
                    raise ValueError('Complete Figure selection document changed')
                check_prefix_cache(cache)
                check_inventory_replay_cache(selection_inventory)
                value['document'] = document
            except BaseException:
                cache.pop(key, None)
                raise
        return value
    root = path.parent
    directory_stamp = complete_capture_directory_stamp(root)
    members, member_directories = capture_member_paths(root, include_markers=True)
    before = {p: evidence.stamp(p) for p in members.values()}
    manifest_raw = small(path)
    cache[key] = None
    try:
        raw_index = {}
        manifest = verify(root, retained_cache=cache, inventory_cache=inventory_cache,
                          _raw_index_out=raw_index)
        if (manifest.get('capture_format') != FILES_STREAM_SCHEMA or
                set(manifest['outputs']) != {*ROLES, 'file-metadata'}):
            raise ValueError('Reuse requires a complete shared Figure stream')
        namespace = small(root / (site_info.PREFIX + 'namespace-registry.tsv'))
        values = stream_values(root / ROLES['figure-sizing'], FILES_STREAM_SCHEMA)
        try:
            header = next(values)
            document = dict(header, records=list(values)) if include_document else None
        finally:
            values.close()
        raw_path = root / ROLES['figure-sizing-raw']
        # The semantic source traversal already decoded every physical record,
        # checked exact EOF and hashed these same bytes. Keep its small index,
        # never a second decoded batch graph or another raw-file traversal.
        if (set(raw_index) != {'header', 'offsets', 'encoding', 'identity', 'stamp'} or
                raw_index['stamp'] != before[raw_path] or
                raw_index['identity'] != {'size': before[raw_path][2],
                                         'sha256': manifest['outputs']['figure-sizing-raw']}):
            raise ValueError('Complete Figure verified raw index differs')
        offsets, encoding = raw_index['offsets'], raw_index['encoding']
        total = raw_index['header']['base_batches'] + raw_index['header']['observed_batches']
        if (total != header['base_batches'] + header['observed_batches'] or
                len(offsets) != total or
                small(path) != manifest_raw or
                {p: evidence.stamp(p) for p in capture_member_paths(root, include_markers=True)[0].values()} != before or
                any(complete_capture_directory_stamp(p) != stamp for p, stamp in member_directories.items()) or
                complete_capture_directory_stamp(root) != directory_stamp):
            raise ValueError('Complete Figure source changed during replay')
        value = {'root': root, 'manifest': manifest, 'manifest_sha256': digest(manifest_raw),
            'namespace': namespace, 'projection_header': header, 'offsets': offsets,
            'raw_path': raw_path, 'raw_encoding': encoding, 'stamps': before, 'directory_stamp': directory_stamp,
            'member_directories': member_directories,
            'inventory': inventory_document(root / INVENTORY),
            'query_inputs': decode(small(root / QUERY_INPUTS)),
            'defaults': inventory_document(root / PLAN)['defaults']}
        if include_document:
            value['document'] = document
        cache[key] = value
        check_prefix_cache(cache)
        return value
    except BaseException:
        cache.pop(key, None)
        raise


def complete_stream_batch(reference, cache):
    if (not isinstance(reference, dict) or set(reference) != {'kind', 'path', 'sha256', 'batch'} or
            reference['kind'] != 'complete-stream' or type(reference['batch']) is not int):
        raise ValueError('Invalid complete Figure batch reference')
    complete = read_complete_capture(Path(reference['path']), cache, include_document=False)
    number = reference['batch']
    if complete['manifest_sha256'] != reference['sha256'] or not 0 <= number < len(complete['offsets']):
        raise ValueError('Complete Figure batch identity changed')
    offset, size, sha = complete['offsets'][number]
    raw_path = complete['raw_path']
    expected_stamp = complete['stamps'][raw_path]
    with raw_path.open('rb') as source:
        def held_stamp():
            value = os.fstat(source.fileno())
            if not stat.S_ISREG(value.st_mode):
                raise ValueError('Complete Figure raw source changed')
            return (value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_ctime_ns)
        if held_stamp() != expected_stamp:
            raise ValueError('Complete Figure raw source changed')
        source.seek(offset)
        raw = source.read(size)
        if held_stamp() != expected_stamp or evidence.stamp(raw_path) != expected_stamp:
            raise ValueError('Complete Figure raw source changed during read')
    if len(raw) != size or digest(raw) != sha:
        raise ValueError('Complete Figure batch bytes changed')
    return raw_record_decode(raw, complete['raw_encoding'])


def _verified_contained_http_leaf(node, slot, batch, cache, namespace, source_stamps):
    """Reuse only an exact HTTP frame in this operation's fully verified tree."""
    value=node['sources'][slot] if slot < node['committed'] else None
    if (value is None or value.get('kind') not in
            ('http-archived','http-archived-light','http-archived-lean')):
        return False
    imported='imported_row'in node
    reference=node['container_reference'] if imported else node['reference']
    if reference.get('kind')!='complete-stream':return False
    container=Path(reference['path']).parent
    if imported:
        if (node['container']!=container or node['root']!=container/node['identifier']
                or node['imported_row']['id']!=node['identifier']):
            raise ValueError('Verified HTTP origin belongs to another container')
    elif node['root']!=container or node['path']!=Path(reference['path']):
        raise ValueError('Verified HTTP source root differs')
    complete=cache.get(('complete-stream',str(reference['path'])))
    if complete is None:return False
    if (complete['root']!=container or complete['manifest_sha256']!=reference['sha256']
            or complete['namespace']!=namespace):
        raise ValueError('Verified HTTP container authority differs')
    if (node['source_rows_sha256'][slot]!=digest(stream_encoded(value)) or
            imported and node['imported_row_sha256']!=digest(encoded(node['imported_row']))):
        raise ValueError('Verified HTTP source journal or origin mapping changed')
    frame=node['imported_row']['frame_map'][slot] if imported else slot
    if type(frame)is not int:
        raise ValueError('Verified HTTP frame is not selected')
    authorities={node['path'],node['root']/PLAN,node['root']/FILE_REQUESTS}
    if imported:authorities.add(container/PLAN)
    for path in authorities:
        expected=complete['stamps'].get(path)
        if expected is None or source_stamps.get(path)!=expected or evidence.stamp(path)!=expected:
            raise ValueError('Verified HTTP journal or authority changed')
    for name in {*value.get('artifacts',[]),*value.get('tiff_artifacts',[])}:
        relative=Path(name)
        if relative.is_absolute() or '..'in relative.parts or relative.as_posix()!=name:
            raise ValueError('Verified HTTP member escapes its origin')
        path=node['root']/relative;expected=complete['stamps'].get(path)
        if expected is None or evidence.stamp(path)!=expected:
            raise ValueError('Verified HTTP source member changed')
    if complete_stream_batch(dict(reference,batch=frame),cache)!=batch:
        raise ValueError('Verified HTTP frame differs from its complete source')
    return True


def validate_metadata_light(batch, namespace, wiki, date):
    """Permit only proved SVG logical axes or existing unsupported/missing facts."""
    result = file_records((batch,), namespace, wiki, date, batch['response'].encode(),
                          has_batches=True, record_limit=50)
    families = result['source_profile']['handler_families']
    for row in result['records']:
        svg = (row['state'] == 'eligible' and row['mime'] in ('image/svg+xml', 'image/svg') and
               row['mediatype'] == 'DRAWING' and row['original_width'] > 0 and row['original_height'] > 0)
        if not svg and row['state'] != 'missing' and (row['state'] != 'unsupported' or
                row['mime'] in families or row['mime'] == 'image/tiff'):
            raise ValueError('Metadata-light response requires proved SVG or unsupported non-TIFF media')
    return result


def lean_tiff_titles(batch, namespace, wiki, date, profile_kind, *, allow_compatible_epochs=False):
    base = {'requests': batch['requests'], 'response': batch['response']}
    result = file_records(iter((base,)), namespace, wiki, date, batch['response'].encode(),
                          has_batches=True, record_limit=50, profile_kind=profile_kind, allow_compatible_epochs=allow_compatible_epochs)
    data = decode(batch['response'].encode())
    if any('metadata' in info for page in data['query']['pages'] for info in page.get('imageinfo', [])):
        raise ValueError('Lean Figure response contains unrequested metadata')
    tiff = {row['requested_file'] for row in result['records'] if row['mime'] == 'image/tiff'}
    return [title for title in batch['requests'] if title in tiff]


def validate_lean_batch(batch, namespace, wiki, date, profile_kind, *, allow_compatible_epochs=False):
    required = lean_tiff_titles(batch, namespace, wiki, date, profile_kind, allow_compatible_epochs=allow_compatible_epochs)
    if bool(required) != ('tiff_metadata_response' in batch):
        raise ValueError('Lean Figure batch lacks its exact required TIFF followup')
    return file_records(iter((batch,)), namespace, wiki, date, batch['response'].encode(),
                        has_batches=True, record_limit=50, profile_kind=profile_kind, allow_compatible_epochs=allow_compatible_epochs)


def source_epoch_pending_batch(root, source, wiki, artifacts):
    names, raw = metadata.verified_batch(root, source['base'], wiki, artifacts,
                                        figure_axes=True, figure_metadata_light=True)
    batch = {'requests': names, 'response': raw.decode('utf-8')}
    if 'tiff' in source:
        _, raw = metadata.verified_batch(root, source['tiff'], wiki, artifacts, figure_axes=True)
        batch['tiff_metadata_response'] = raw.decode('utf-8')
    return batch


def read_source_epoch_prefix(path, cache=None):
    path = Path(path)
    raw = small(path)
    key = (str(path), digest(raw))
    if cache is not None and key in cache:
        result = cache[key]
        if result is None:
            raise ValueError('Cyclic closed Figure source transition')
        if (complete_capture_directory_stamp(result['source_root']) != result['source_directory_stamp'] or
                any(evidence.stamp(p) != result['stamps'][p] for p in
                    (path, result['raw_path'], result['closure_path']))):
            raise ValueError('Closed Figure source transition changed')
        return result
    if cache is not None:
        cache[key] = None
    try:
        result = _read_source_epoch_prefix(path, raw, cache)
    except BaseException:
        if cache is not None:
            cache.pop(key, None)
        raise
    if cache is not None:
        cache[key] = result
    return result


def _read_source_epoch_prefix(path, raw, cache):
    record = decode(raw)
    if (not isinstance(record, dict) or set(record) != {
            'schema', 'wiki', 'date', 'source_root', 'original_root', 'closure', 'source_epochs'} or
            record['schema'] != SOURCE_PREFIX_SCHEMA or
            record['source_epochs'] != [FIGURE_CURRENT_CORE, FIGURE_RESPONSE_CORE]):
        raise ValueError('Invalid closed Figure source transition')
    wiki, date = record['wiki'], record['date']
    wiktionary_api(wiki)
    if not isinstance(date, str) or re.fullmatch(r'\d{8}', date) is None:
        raise ValueError('Invalid closed Figure source edition/date')
    root, original = Path(record['source_root']), Path(record['original_root'])
    if any(not p.is_absolute() or p.resolve() != p or p.is_symlink() for p in (path, root, original)):
        raise ValueError('Unsafe closed Figure source locator')
    if (root / MANIFEST).exists() or (root / COMPLETE).exists():
        raise ValueError('Closed Figure source transition is already published')
    directory_stamp = complete_capture_directory_stamp(root)
    closure_ref = record['closure']
    if not isinstance(closure_ref, dict) or set(closure_ref) != {'path', 'bytes', 'sha256'}:
        raise ValueError('Invalid closed Figure source closure')
    closure_path = Path(closure_ref['path'])
    if not closure_path.is_absolute() or closure_path.resolve() != closure_path or closure_path.is_symlink():
        raise ValueError('Unsafe closed Figure source closure')
    closure = decode(metadata.checkpoint_read(closure_path, closure_ref))
    if (closure.get('outcome') != 'FAILED-PHYSICALLY-SOURCE-CLOSED' or
            any(closure.get(k) is not True for k in
                ('source_after', 'reaped', 'dual_proc_absence', 'ps_absence', 'allocation_released')) or
            type(closure.get('terminal')) is not int or closure['terminal'] == 0 or
            closure.get('detail') != 'Lean Figure and defaults source versions differ'):
        raise ValueError('Figure source transition lacks exact failure closure')
    stamps = {path: evidence.stamp(path), closure_path: evidence.stamp(closure_path)}
    refs = closure.get('retained_metadata')
    if not isinstance(refs, dict) or set(refs) != {'failure', 'plan', 'journal'}:
        raise ValueError('Figure source transition lacks retained evidence')
    bound = {}
    for role, ref in refs.items():
        if not isinstance(ref, dict) or set(ref) != {'path', 'bytes', 'sha256'}:
            raise ValueError('Invalid Figure source evidence descriptor')
        old = Path(ref['path'])
        if old.parent != original:
            raise ValueError('Figure source evidence escaped original generation')
        local = root / observed_artifact_name(old.name)
        before = evidence.stamp(local)
        if prefix_identity(local, before[2]) != {'bytes': ref['bytes'], 'sha256': ref['sha256']}:
            raise ValueError('Figure source evidence changed')
        stamps[local] = before
        bound[role] = local
    if bound['plan'] != root / PLAN or bound['journal'] != root / FILE_REQUESTS:
        raise ValueError('Figure source transition uses different plan/journal roles')
    failure, plan = inventory_document(bound['failure']), inventory_document(bound['plan'])
    if (plan.get('wiki') != wiki or plan.get('date') != date or
            failure.get('plan_sha256') != digest(encoded(plan)) or
            failure.get('source') != plan.get('source') or
            failure.get('error') != closure['detail'] or failure.get('resumes') != [] or
            plan.get('observed_batches') != 0 or plan.get('observed') != [] or
            plan.get('metadata_mode') != 'lean-tiff-v1' or plan.get('figure_profile') != FIGURE_PROFILE_V4):
        raise ValueError('Figure source transition changed the original selected plan')
    committed = failure.get('committed_batches')
    if (type(committed) is not int or not 0 < committed < plan.get('base_batches', 0) or
            closure.get('committed_batches') != committed):
        raise ValueError('Invalid closed Figure source prefix count')
    files = failure.get('artifacts')
    if not isinstance(files, dict):
        raise ValueError('Missing closed Figure source inventory')
    for name, ref in files.items():
        observed_artifact_name(name)
        if not isinstance(ref, dict) or set(ref) != {'bytes', 'sha256'}:
            raise ValueError('Invalid closed Figure source member')
        local = root / name
        before = evidence.stamp(local)
        if prefix_identity(local, before[2]) != ref or (local in stamps and stamps[local] != before):
            raise ValueError('Closed Figure source member changed')
        stamps[local] = before
    members = {*files, bound['failure'].name}
    if {p.name for p in root.iterdir()} != members:
        raise ValueError('Closed Figure source has unaccounted members')
    namespace = small(root / (site_info.PREFIX + 'namespace-registry.tsv'))
    inventory = inventory_document(root / INVENTORY)
    query_inputs = decode(small(root / QUERY_INPUTS))
    if (digest(namespace) != plan['namespace_registry_sha256'] or
            digest(encoded(inventory)) != plan['inventory_sha256'] or query_inputs != plan['query_inputs']):
        raise ValueError('Closed Figure source inputs changed')
    desired = set(inventory['titles']) | provider_query_titles(root, query_inputs, namespace, wiki, date)
    site_raw = small(root / ROLES['figure-sizing-site'], MAX_RESPONSE)
    if decode(site_raw)['query']['general'].get('git-hash') != FIGURE_CURRENT_CORE:
        raise ValueError('Closed Figure source transition has no original epoch')
    raw_path = root / ROLES['figure-sizing-raw']
    offsets, pending_batches, used, retained_used, http_files = [], [], set(), set(), set()
    retained = plan['retained']
    if not isinstance(retained, list) or len(retained) > committed:
        raise ValueError('Closed Figure source retained prefix is incomplete')
    encoding = None
    def batches():
        nonlocal encoding
        with raw_path.open('rb') as source, (root / FILE_REQUESTS).open('rb') as journal:
            raw_line, journal_line = source.readline(STREAM_HEADER_LIMIT+1), journal.readline(STREAM_HEADER_LIMIT+1)
            if max(len(raw_line), len(journal_line)) > STREAM_HEADER_LIMIT:
                raise ValueError('Closed Figure source header exceeds bound')
            header = stream_decode(raw_line)
            encoding = raw_record_encoding(header)
            expected = {'schema': RAW_STREAM_SCHEMA, 'wiki': wiki, 'core_revision': FIGURE_CURRENT_CORE,
                'namespace_registry_sha256': digest(namespace), 'records_count': len(desired),
                'base_batches': plan['base_batches'], 'observed_batches': 0}
            if encoding is not None:
                expected['record_encoding'] = encoding
            if header != expected or stream_decode(journal_line) != {'schema': REQUEST_STREAM_SCHEMA, 'batches': plan['base_batches']}:
                raise ValueError('Closed Figure source headers changed')
            planned = None
            for index in range(committed):
                offset = source.tell()
                line, source_line = source.readline(STREAM_RAW_LINE_LIMIT+1), journal.readline(STREAM_HEADER_LIMIT+1)
                if len(line) > STREAM_RAW_LINE_LIMIT or len(source_line) > STREAM_HEADER_LIMIT:
                    raise ValueError('Closed Figure source record exceeds bound')
                batch, authority = raw_record_decode(line, encoding), stream_decode(source_line)
                replay_source(root, authority, batch, wiki, date, namespace, http_files, cache,
                              profile_kind=FIGURE_PROFILE_V4, origin_plan=plan)
                names = set(batch['requests'])
                if (names & used or not names <= desired or
                        set(batch) - {'requests', 'response', 'tiff_metadata_response'} or
                        decode(batch['response'].encode())['query']['general'].get('git-hash') != FIGURE_CURRENT_CORE):
                    raise ValueError('Closed Figure source committed identity changed')
                if index < len(retained):
                    if authority != retained[index]:
                        raise ValueError('Closed Figure source retained order changed')
                    retained_used.update(names)
                else:
                    if planned is None:
                        planned = list(metadata.title_batches(wiki, sorted(desired-retained_used, key=lambda t:t.encode()),
                                                              plan['batch_size'], figure_axes=True))
                    if authority['kind'] != 'http-archived-lean' or batch['requests'] != planned[index-len(retained)]:
                        raise ValueError('Closed Figure source HTTP order changed')
                used.update(names)
                offsets.append((offset, len(line), digest(line)))
                yield batch
            if source.read(1) or journal.read(1):
                raise ValueError('Closed Figure source has trailing uncommitted data')
        if planned is None:
            planned = list(metadata.title_batches(wiki, sorted(desired-retained_used, key=lambda t:t.encode()),
                                                  plan['batch_size'], figure_axes=True))
        if digest(encoded(planned)) != plan['planned_requests_sha256']:
            raise ValueError('Closed Figure source HTTP plan changed')
        pending = pending_http_records(root, plan, failure, planned, allow_compatible_epochs=True)
        first = committed-len(retained)+1
        if not pending or sorted(pending) != list(range(first, first+len(pending))):
            raise ValueError('Closed Figure source pending slots are incomplete')
        for number, state in sorted(pending.items()):
            if state['accepted'] is None:
                raise ValueError('Closed Figure source pending stage is not accepted')
            reference = {'base': state['accepted']}
            if state.get('tiff') is not None:
                if state['tiff']['accepted'] is None:
                    raise ValueError('Closed Figure source TIFF stage is incomplete')
                reference['tiff'] = state['tiff']['accepted']
            batch = source_epoch_pending_batch(root, reference, wiki, set(files))
            validate_lean_batch(batch, namespace, wiki, date, FIGURE_PROFILE_V4, allow_compatible_epochs=True)
            if (batch['requests'] != planned[number-1] or set(batch['requests']) & used or
                    not set(batch['requests']) <= desired or
                    decode(batch['response'].encode())['query']['general'].get('git-hash') != FIGURE_RESPONSE_CORE):
                raise ValueError('Closed Figure source pending epoch or identity changed')
            used.update(batch['requests']); http_files.update(state['artifacts'])
            pending_batches.append(reference)
            yield batch
    document = file_records(batches(), namespace, wiki, date, site_raw, has_batches=True,
        record_limit=len(desired), profile_kind=FIGURE_PROFILE_V4, allow_compatible_epochs=True)
    expected = {*plan['defaults'], ROLES['figure-siteinfo'], ROLES['figure-sizing-raw'],
        ROLES['figure-sizing-site'], INVENTORY, PLAN, FILE_REQUESTS, QUERY_INPUTS,
        *http_files, *(row['path'] for row in query_inputs)}
    if (set(files) != expected or {p.name for p in root.iterdir()} != members or
            complete_capture_directory_stamp(root) != directory_stamp or
            any(evidence.stamp(p) != stamp for p, stamp in stamps.items())):
        raise ValueError('Closed Figure source evidence changed during replay')
    return {'record': record, 'plan': plan, 'namespace': namespace, 'document': document,
        'offsets': offsets, 'raw_path': raw_path, 'raw_encoding': encoding, 'stamps': stamps,
        'source_root': root, 'source_directory_stamp': directory_stamp, 'closure_path': closure_path,
        'members': members, 'light_titles': [], 'inventory': inventory,
        'query_inputs': query_inputs, 'pending_batches': pending_batches,
        'batch_count': len(offsets)+len(pending_batches)}


def read_closed_prefix(path, cache=None):
    """Replay a closed oversize failure once per verification boundary.

    The original failed generation remains read-only. Only accepted lines are
    indexed; the truncated response is authenticated evidence, never file facts.
    """
    path = Path(path)
    raw = small(path)
    if decode(raw).get('schema') == SOURCE_PREFIX_SCHEMA:
        return read_source_epoch_prefix(path, cache)
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
    members = set()
    for local in sorted(root.iterdir()):
        if local.name in (MANIFEST, COMPLETE):
            continue
        evidence.stamp(local)
        members.add(local.name)
    if members != {*files, failure_path.name}:
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
    old_planned, lookahead, encoding = None, None, None

    def batches():
        nonlocal old_planned, lookahead, encoding
        with raw_path.open('rb') as source, (root / FILE_REQUESTS).open('rb') as journal:
            header_line, journal_line = source.readline(STREAM_HEADER_LIMIT+1), journal.readline(STREAM_HEADER_LIMIT+1)
            if max(len(header_line), len(journal_line)) > STREAM_HEADER_LIMIT:
                raise ValueError('Closed Figure header exceeds its bound')
            expected = {'schema': RAW_STREAM_SCHEMA, 'wiki': wiki,
                'core_revision': decode(site_raw)['query']['general']['git-hash'],
                'namespace_registry_sha256': digest(namespace), 'records_count': len(desired),
                'base_batches': plan['base_batches'], 'observed_batches': 0}
            raw_header = stream_decode(header_line)
            encoding = raw_record_encoding(raw_header)
            if encoding is not None:
                expected['record_encoding'] = encoding
            if (raw_header != expected or stream_decode(journal_line) !=
                    {'schema': REQUEST_STREAM_SCHEMA, 'batches': plan['base_batches']}):
                raise ValueError('Closed Figure stream headers differ')
            for index in range(committed):
                offset = source.tell()
                line, source_line = source.readline(STREAM_RAW_LINE_LIMIT+1), journal.readline(STREAM_HEADER_LIMIT+1)
                if len(line) > STREAM_RAW_LINE_LIMIT or len(source_line) > STREAM_HEADER_LIMIT:
                    raise ValueError('Closed Figure record exceeds its bound')
                batch, authority = raw_record_decode(line, encoding), stream_decode(source_line)
                replay_source(root, authority, batch, wiki, date, namespace, http_files, origin_plan=plan)
                names = set(batch['requests'])
                if names & used or not names <= desired or 'observed_svg_width_px' in batch or 'observed_svg_occurrences' in batch:
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
        if plan.get('max_inflight') == 2:
            pending = pending_http_records(root, plan, failure, old_planned,
                closed_oversize=(receipt_path.name, receipt))
            first = committed-len(retained)+1
            if request_path.name != f'file-metadata.request-{first:06d}.json':
                raise ValueError('Closed oversize request numbering changed')
            for item in pending.values():
                http_files.update(item['artifacts'])
            if first+1 in pending:
                lookahead = pending[first+1]['accepted']
                if lookahead is None:
                    raise ValueError('Closed oversize lookahead was not accepted')
                names, response = metadata.verified_batch(root, lookahead, wiki, set(files), figure_axes=True)
                if (names != old_planned[first] or set(names) & used or
                        set(names) & set(titles) or not set(names) <= desired):
                    raise ValueError('Closed accepted lookahead differs from its disjoint planned names')
                used.update(names)
                yield {'requests': names, 'response': response.decode('utf-8')}
    result = file_records(batches(), namespace, wiki, date, site_raw, has_batches=True, record_limit=len(desired),
                          profile_kind=plan.get('figure_profile', FIGURE_PROFILE_V3))
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
        'offsets': offsets, 'raw_path': raw_path, 'raw_encoding': encoding, 'stamps': stamps, 'light_titles': light,
        'failed_titles': titles, 'inventory': inventory, 'query_inputs': query_inputs,
        'lookahead': lookahead, 'batch_count': len(offsets)+(lookahead is not None)}
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
    if not 0 <= number < prefix['batch_count']:
        raise ValueError('Closed Figure batch index outside accepted prefix')
    if number >= len(prefix['offsets']) and 'pending_batches' in prefix:
        source = prefix['pending_batches'][number-len(prefix['offsets'])]
        return source_epoch_pending_batch(Path(prefix['record']['source_root']), source,
            prefix['record']['wiki'], {p.name for p in prefix['stamps']})
    if number == len(prefix['offsets']):
        names, response = metadata.verified_batch(Path(prefix['record']['source_root']),
            prefix['lookahead'], prefix['record']['wiki'],
            {p.name for p in prefix['stamps']}, figure_axes=True)
        return {'requests': names, 'response': response.decode('utf-8')}
    offset, size, sha = prefix['offsets'][number]
    with prefix['raw_path'].open('rb') as source:
        source.seek(offset)
        raw = source.read(size)
    if len(raw) != size or digest(raw) != sha:
        raise ValueError('Accepted Figure prefix line changed')
    return raw_record_decode(raw, prefix['raw_encoding'])


def check_prefix_cache(cache):
    for prefix in cache.values():
        if prefix is None:
            continue  # An outer complete-source replay is still in progress.
        if (('source_root' in prefix and (
                {p.name for p in prefix['source_root'].iterdir()} != prefix['members'] or
                complete_capture_directory_stamp(prefix['source_root']) != prefix['source_directory_stamp'])) or
                (prefix.get('root') is not None and
                 set(capture_member_paths(prefix['root'], include_markers=True)[0].values()) != set(prefix['stamps'])) or
                any(complete_capture_directory_stamp(p) != stamp
                    for p, stamp in prefix.get('member_directories', {}).items()) or
                ('directory_stamp' in prefix and
                 complete_capture_directory_stamp(prefix['root']) != prefix['directory_stamp']) or
                any(evidence.stamp(p) != stamp for p, stamp in prefix['stamps'].items())):
            raise ValueError('Closed Figure prefix changed during use')


def selected_inventory(args, namespace, *, inventory_cache=None):
    prepared = getattr(args, 'prepared_inventory', None)
    if prepared is None:
        return verified_source_inventory(namespace, args.wiki, args.date, small(args.dumpstatus), args.sql, inventory_cache)
    inventory, stamps = prepared
    paths = {Path(path).resolve() for path in args.sql}
    if (set(stamps) != paths or any(evidence.stamp(path) != before for path, before in stamps.items()) or
            inventory.get('wiki') != args.wiki or inventory.get('date') != args.date or
            inventory.get('namespace_registry_sha256') != digest(namespace) or
            inventory.get('dumpstatus_raw') != small(args.dumpstatus).decode('utf-8') or
            {Path(row['path']) for row in inventory.get('sources', [])} != paths):
        raise ValueError('Invocation-local Figure inventory changed')
    return inventory


def capture_files(args, transport=None, sleep=time.sleep, *, target_contract=REPLAY_CONTRACT,
                  _after_capture=None):
    """Capture or append with an explicit v4/v6 policy; ordinary callers keep v6."""
    if target_contract not in (REPLAY_CONTRACT_V4, REPLAY_CONTRACT):
        raise ValueError('Unsupported Figure capture replay contract')
    root = Path(args.output)
    for source in getattr(args, 'reuse', []):
        if root.resolve().is_relative_to(Path(source).resolve()):
            raise ValueError('Figure capture cannot modify a retained source')
    # The proof may live outside its failed generation. Reject an output inside
    # that generation before even creating the capture lock or its parent.
    for path in getattr(args, 'reuse_batch', []):
        record = decode(small(Path(path)))
        if (isinstance(record, dict) and record.get('schema') == SCHEMA and
                record.get('capture_format') == FILES_STREAM_SCHEMA and
                root.resolve().is_relative_to(Path(path).parent.resolve())):
            raise ValueError('Figure capture cannot modify a complete source')
        if isinstance(record, dict) and record.get('schema') in CLOSED_PREFIX_SCHEMAS:
            source_root = record.get('source_root')
            if not isinstance(source_root, str) or root.resolve().is_relative_to(Path(source_root).resolve()):
                raise ValueError('Figure capture cannot modify its closed prefix source')
    root.parent.mkdir(parents=True, exist_ok=True)
    lock = root.with_name('.'+root.name+'.capture.lock')
    verification_caches = None if _after_capture is None else {'retained': {}, 'inventory': {}}
    fd = os.open(lock, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.getuid():
            raise ValueError('Unsafe Figure capture lock')
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        result = _capture_files(args, transport=transport, sleep=sleep, target_contract=target_contract,
                                _verification_caches=verification_caches)
        if _after_capture is not None:
            # The maintained caller completes ordinary tuple validation while
            # this lock and these guarded ancestor proofs still belong to us.
            verification_caches['output_check']()
            check_prefix_cache(verification_caches['retained'])
            check_inventory_replay_cache(verification_caches['inventory'])
            _after_capture(root, retained_cache=verification_caches['retained'],
                           inventory_cache=verification_caches['inventory'])
            check_prefix_cache(verification_caches['retained'])
            check_inventory_replay_cache(verification_caches['inventory'])
            verification_caches['output_check']()
        return result
    finally:
        if verification_caches is not None:
            verification_caches['retained'].clear()
            verification_caches['inventory'].clear()
            verification_caches.clear()
        os.close(fd)


def _capture_files(args, transport=None, sleep=time.sleep, *, target_contract=REPLAY_CONTRACT,
                   _verification_caches=None):
    replay_policy = dict(allow_tiff_companion=True, allow_compatible_epochs=True,
                         allow_decimal_tiff_axes=True,
                         allow_default_tiff_page=target_contract == REPLAY_CONTRACT)
    mode = getattr(args, 'metadata_mode', 'full')
    if mode not in ('full', 'lean-tiff-v1'):
        raise ValueError('Invalid Figure metadata acquisition mode')
    lean = mode == 'lean-tiff-v1'
    max_inflight = getattr(args, 'max_inflight', 1)
    if type(max_inflight) is not int or max_inflight not in (1, 2):
        raise ValueError('Figure capture supports one or two occupied request slots')
    profile_kind = getattr(args, 'figure_profile', FIGURE_PROFILE_V3)
    if profile_kind not in (FIGURE_PROFILE_V3, FIGURE_PROFILE_V4, FIGURE_PROFILE_V5):
        raise ValueError('Unreviewed selected Figure handler profile')
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
    inventory_cache = {} if _verification_caches is None else _verification_caches['inventory']
    inventory = selected_inventory(args, namespace, inventory_cache=inventory_cache)
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
    prefix_cache = {} if _verification_caches is None else _verification_caches['retained']
    retained, observed, light_titles = [], [], set()
    closed_prefixes = []
    complete_captures = []
    def retain_complete(path):
        path = Path(path).absolute()
        complete = read_complete_capture(path, prefix_cache, inventory_cache=inventory_cache)
        if (complete_captures or complete['manifest']['wiki'] != args.wiki or
                complete['manifest']['date'] != args.date or complete['namespace'] != namespace or
                complete['inventory'] != inventory or
                query_inputs[:len(complete['query_inputs'])] != complete['query_inputs'] or
                complete['defaults'] != artifacts):
            raise ValueError('Complete Figure input selection differs')
        names = {row['requested_file'] for row in complete['document']['records']}
        # New requested names must come from authenticated appended query logs;
        # all original parent facts and query-log bytes remain selected.
        if not names <= desired or names & used:
            raise ValueError('Complete Figure source duplicates or selects unobserved files')
        reference = {'kind': 'complete-stream', 'path': str(path),
                     'sha256': complete['manifest_sha256']}
        complete_captures.append(reference)
        base = complete['document']['base_batches']
        retained.extend(dict(reference, batch=i) for i in range(base))
        observed.extend(dict(reference, batch=i) for i in range(base, len(complete['offsets'])))
        used.update(names)
    # Retain descriptors, not response strings. Each source is replayed lazily.
    for path in args.reuse:
        raw = small(Path(path) / MANIFEST)
        if decode(raw).get('capture_format') == FILES_STREAM_SCHEMA:
            retain_complete(Path(path) / MANIFEST)
            continue
        batch = retained_file_batch(path, args.wiki, args.date)
        names = set(batch['requests'])
        if names <= desired and not names & used:
            retained.append({'kind': 'retained-occurrences', 'path': str(Path(path).resolve()), 'manifest_sha256': digest(raw)})
            used.update(names)
    for path in getattr(args, 'reuse_batch', []):
        raw = small(Path(path))
        if decode(raw).get('schema') == SCHEMA and decode(raw).get('capture_format') == FILES_STREAM_SCHEMA:
            retain_complete(Path(path))
            continue
        if decode(raw).get('schema') in CLOSED_PREFIX_SCHEMAS:
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
            retained.extend(dict(reference, batch=i) for i in range(prefix['batch_count']))
            used.update(names)
            light_titles.update(prefix['light_titles'])
            continue
        batch = retained_metadata_batch(path, args.wiki, args.date, namespace)
        names = set(batch['requests'])
        jpeg_supplement = 'jpeg_metadata_only' in batch
        supplemental = 'observed_svg_width_px' in batch or 'observed_svg_occurrences' in batch or jpeg_supplement
        if (not names <= desired and not jpeg_supplement) or (names & used and not supplemental):
            raise ValueError('Retained file batch has duplicate or unselected names')
        source = {'kind': 'retained-request', 'path': str(Path(path).resolve()), 'sha256': digest(raw)}
        (observed if supplemental else retained).append(source)
        if not supplemental:
            used.update(names)
    remaining = sorted(desired - used, key=lambda name: name.encode('utf-8'))
    # Reserve the full query's URL budget so even an all-TIFF response has one
    # bounded followup with the same ordered subset of at most fifty titles.
    planned = list(metadata.title_batches(args.wiki, remaining, args.batch_size, figure_axes=True))
    if light_titles and not lean:
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
    if (total > 0xffffffff or not base_count <= len(desired) <= 50*base_count or
            (not desired and observed_count != 0)):
        raise ValueError('Figure inventory exceeds checked stream count representation')
    raw_bound = STREAM_HEADER_LIMIT + total*STREAM_RAW_LINE_LIMIT
    projection_bound = STREAM_HEADER_LIMIT + len(desired)*STREAM_FACT_LINE_LIMIT
    if max(raw_bound, projection_bound) >= 2**64:
        raise ValueError('Figure stream plan byte count overflow')
    plan = {'schema': 'wikidict.figure-capture-plan.v1', 'wiki': args.wiki, 'date': args.date,
            'replay_contract': target_contract,
            'source': capture_source(), 'namespace_registry_sha256': digest(namespace),
            'inventory_sha256': digest(encoded(inventory)), 'defaults': artifacts,
            'query_inputs': query_inputs, 'retained': retained, 'observed': observed,
            'planned_requests_sha256': digest(encoded(planned)), 'records_count': len(desired),
            'base_batches': base_count, 'observed_batches': observed_count,
            'raw_byte_upper_bound': raw_bound, 'projection_byte_upper_bound': projection_bound,
            'batch_size': args.batch_size, 'delay': args.delay, 'pacing': 'start-to-start'}
    if lean:
        plan['metadata_mode'] = mode
    if profile_kind != FIGURE_PROFILE_V3:
        plan['figure_profile'] = profile_kind
    if max_inflight == 2:
        plan['max_inflight'] = 2
    if closed_prefixes:
        plan.update(closed_prefixes=closed_prefixes, metadata_light_titles=sorted(light_titles, key=lambda t:t.encode()))
    if complete_captures:
        plan['complete_captures'] = complete_captures
    resumes, committed, http_files = [], 0, set()
    if resume_path is not None:
        if inventory_document(root / PLAN) != plan:
            raise ValueError('Figure resume source, input or request plan changed')
        ref_id = evidence.fingerprint(Path(resume_path))
        reference = {'path': Path(resume_path).name, 'bytes': ref_id['size'], 'sha256': ref_id['sha256']}
        proof = read_resume(root, reference, plan, live=True, planned=planned)
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
    pending_http = proof.get('_pending_http', {}) if resume_path is not None else {}
    if pending_http:
        # A TIFF followup may still be pending. Its lean identity is usable for
        # conflict checks only; no provisional unsupported state is published.
        incomplete = []
        def known_batches():
            with (root/ROLES['figure-sizing-raw']).open('rb') as source:
                header_line = source.readline(STREAM_HEADER_LIMIT+1)
                if len(header_line) > STREAM_HEADER_LIMIT:
                    raise ValueError('Pending Figure header exceeds its bound')
                encoding = raw_record_encoding(stream_decode(header_line))
                for _ in range(committed):
                    yield raw_record_decode(source.readline(STREAM_RAW_LINE_LIMIT+1), encoding)
            for number, state in sorted(pending_http.items()):
                if state['accepted'] is None:
                    continue
                titles, raw = metadata.verified_batch(root, state['accepted'], args.wiki,
                    set(proof['_failure']['artifacts']), figure_axes=True,
                    figure_metadata_light=lean or set(planned[number-1]) <= light_titles)
                batch = {'requests': titles, 'response': raw.decode('utf-8')}
                if lean:
                    needed = lean_tiff_titles(batch, namespace, args.wiki, args.date, profile_kind, allow_compatible_epochs=True)
                    followup = state.get('tiff', {}).get('accepted')
                    if needed and followup is None:
                        incomplete.append(file_records(iter((batch,)), namespace, args.wiki, args.date,
                            site_raw, has_batches=True, record_limit=50, profile_kind=profile_kind, **replay_policy)['records'])
                        continue
                    if followup is not None:
                        _, raw = metadata.verified_batch(root, followup, args.wiki,
                            set(proof['_failure']['artifacts']), figure_axes=True)
                        batch['tiff_metadata_response'] = raw.decode('utf-8')
                yield batch
        known = file_records(known_batches(), namespace, args.wiki, args.date, site_raw,
                             has_batches=True, record_limit=len(desired), profile_kind=profile_kind, **replay_policy)
        if incomplete:
            canonical, requested = {}, {}
            for row in itertools.chain(known['records'], *(rows for rows in incomplete)):
                facts = file_fact_identity(row)
                identity = (facts[0], *facts[2:])
                if row['requested_file'] in requested or row['requested_file'] not in desired:
                    raise ValueError('Pending lean identity duplicates or adds a selected request')
                requested[row['requested_file']] = identity
                previous = canonical.setdefault(row['canonical_file'], identity)
                if previous != identity:
                    raise ValueError('Pending lean response conflicts with a known canonical identity')
            for title, identity in requested.items():
                if title in canonical and canonical[title] != identity:
                    raise ValueError('Pending lean request conflicts with its known canonical alias')
    committed_http = max(0, min(committed-len(retained), len(planned)))
    def fetch_stage(number, titles, state, *, stage='', light=True):
        state = state or {}
        if state.get('accepted') is not None:
            reference = state['accepted']
            _, raw = metadata.verified_batch(root, reference, args.wiki,
                set(proof['_failure']['artifacts']), figure_axes=True, figure_metadata_light=light)
            return metadata.classify_response(decode(raw), titles, registry), reference
        prefix = 'file-metadata.' + (stage+'-' if stage else '')
        if not state:
            metadata.document(root/f'{prefix}request-{number:06d}.json', {
                'titles': titles,
                'query': metadata.query_for(args.wiki, titles, figure_axes=True, figure_metadata_light=light),
                'url': metadata.query_url(args.wiki, titles, figure_axes=True, figure_metadata_light=light)})
        return metadata.request_batch(root, number, titles, registry,
            transport or evidence.get_response, sleep, deadline, args.delay, pacing, figure_axes=True,
            figure_metadata_light=light, first_attempt=state.get('first_attempt', 1),
            prepared_request=True, artifact_stage=stage)
    def fetch(number):
        state = pending_http.get(number, {})
        if lean:
            rows, base = fetch_stage(number, planned[number-1], state)
            names, raw, _, _ = captured_http_stage(root, base, args.wiki, light=True)
            batch = {'requests': names, 'response': raw.decode('utf-8')}
            if not figure_source_compatible(decode(raw)['query']['general']['git-hash'],
                    decode(saved[site_info.SNAPSHOT])['query']['general'].get('git-hash')):
                raise ValueError('Lean Figure and defaults source versions differ')
            titles = lean_tiff_titles(batch, namespace, args.wiki, args.date, profile_kind, allow_compatible_epochs=True)
            reference = {'base': base}
            if titles:
                _, reference['tiff'] = fetch_stage(number, titles, state.get('tiff'), stage='tiff', light=False)
                _, raw, _, _ = captured_http_stage(root, reference['tiff'], args.wiki, light=False, stage='tiff')
                batch['tiff_metadata_response'] = raw.decode('utf-8')
            validate_lean_batch(batch, namespace, args.wiki, args.date, profile_kind, allow_compatible_epochs=True)
            return rows, reference
        if state.get('accepted') is not None:
            reference = state['accepted']
            titles, raw = metadata.verified_batch(root, reference, args.wiki,
                set(proof['_failure']['artifacts']), figure_axes=True,
                figure_metadata_light=set(planned[number-1]) <= light_titles)
            return metadata.classify_response(decode(raw), titles, registry), reference
        prepared = max_inflight == 2
        if prepared and not state:
            titles = planned[number-1]
            light = set(titles) <= light_titles
            # Archive before reserving the start slot: a slow fsync must not
            # compress the interval between two subsequent transport calls.
            metadata.document(root/f'file-metadata.request-{number:06d}.json', {
                'titles': titles,
                'query': metadata.query_for(args.wiki, titles, figure_axes=True, figure_metadata_light=light),
                'url': metadata.query_url(args.wiki, titles, figure_axes=True, figure_metadata_light=light)})
        return metadata.request_batch(root, number, planned[number-1], registry,
            transport or evidence.get_response, sleep, deadline, args.delay, pacing, figure_axes=True,
            figure_metadata_light=set(planned[number-1]) <= light_titles,
            first_attempt=state.get('first_attempt', 1), prepared_request=prepared)
    slots = (metadata.OrderedRequestBatches(fetch, committed_http+1, len(planned), pacing,
              warm=bool(retained or committed), wall_errors=WALL_ERRORS) if max_inflight == 2 else None)
    raw_path, request_path = root / ROLES['figure-sizing-raw'], root / FILE_REQUESTS
    count = committed
    def retained_batch(source):
        if source['kind'] == 'complete-stream':
            return complete_stream_batch(source, prefix_cache)
        if source['kind'] == 'closed-prefix':
            return closed_prefix_batch(source, prefix_cache)
        if source['kind'] == 'retained-occurrences':
            return retained_file_batch(Path(source['path']), args.wiki, args.date)
        return retained_metadata_batch(Path(source['path']), args.wiki, args.date, namespace)
    def iterator():
        nonlocal site_raw, count
        encoding = RAW_RECORD_ENCODING
        if resume_path is not None:
            archived = {}
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
                encoding = raw_record_encoding(header)
                if encoding is not None:
                    expected_header['record_encoding'] = encoding
                if header != expected_header or stream_decode(source_line) != {'schema': REQUEST_STREAM_SCHEMA, 'batches': total}:
                    raise ValueError('Figure checkpoint stream headers differ')
                for index in range(committed):
                    line = old_raw.readline(STREAM_RAW_LINE_LIMIT+1)
                    source_line = old_sources.readline(STREAM_HEADER_LIMIT+1)
                    if len(line) > STREAM_RAW_LINE_LIMIT or len(source_line) > STREAM_HEADER_LIMIT:
                        raise ValueError('Figure checkpoint record exceeds its bound')
                    batch, source = raw_record_decode(line, encoding), stream_decode(source_line)
                    replay_source(root, source, batch, args.wiki, args.date, namespace, http_files, prefix_cache, profile_kind=profile_kind, allow_compatible_epochs=True, origin_plan=plan)
                    record_http_archive(root, source, batch, archived, origin_plan=plan)
                    if index < len(retained):
                        if source != retained[index]:
                            raise ValueError('Figure retained prefix order differs')
                    elif index < base_count:
                        expected_kind = ('http-archived-lean' if lean else
                            'http-archived-light' if set(batch['requests']) <= light_titles else 'http-archived')
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
                previous = read_resume(root, resume, plan, live=False, planned=planned, archived=archived)
                allowed.update((resume['path'], previous['failure']['path']))
                allowed.update(name for state in previous['_pending_http'].values()
                               for name in state['artifacts'] if (root/name).exists())
            if set(payload(root)) != allowed:
                raise ValueError('Figure checkpoint contains uncommitted HTTP or publication artifacts')
        with (append_prefix(raw_path, raw_size) if resume_path is not None else raw_path.open('xb')) as raw_output, \
                (append_prefix(request_path, journal_size) if resume_path is not None else request_path.open('xb')) as request_output:
            if resume_path is None:
                request_output.write(stream_encoded({'schema': REQUEST_STREAM_SCHEMA, 'batches': total}))
            for index in range(committed, total):
                accepted_path = None
                accepted_paths = []
                if time.monotonic() >= deadline:
                    raise ValueError('Capture wall deadline reached')
                if index < len(retained):
                    source = retained[index]
                    batch = retained_batch(source)
                elif index < base_count:
                    number = index-len(retained)+1
                    titles = planned[number-1]
                    light = set(titles) <= light_titles
                    _, reference = slots.next(number) if slots is not None else fetch(number)
                    if lean:
                        actual, response, names, accepted = captured_http_stage(root, reference['base'], args.wiki, light=True)
                        batch = {'requests': actual, 'response': response.decode('utf-8')}
                        source = {'kind': 'http-archived-lean', 'batch': reference['base'], 'artifacts': names}
                        accepted_paths.append(accepted)
                        if 'tiff' in reference:
                            _, raw, names, accepted = captured_http_stage(root, reference['tiff'], args.wiki, light=False, stage='tiff')
                            batch['tiff_metadata_response'] = raw.decode('utf-8')
                            source.update(tiff_batch=reference['tiff'], tiff_artifacts=names)
                            accepted_paths.append(accepted)
                        validate_lean_batch(batch, namespace, args.wiki, args.date, profile_kind, allow_compatible_epochs=True)
                    else:
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
                line = raw_record_encoded(batch, encoding)
                if len(line) > STREAM_RAW_LINE_LIMIT or len(batch['response'].encode()) > MAX_RESPONSE:
                    raise ValueError('Figure response record exceeds its bound')
                if index == 0:
                    site_raw = batch['response'].encode()
                    if not figure_source_compatible(decode(site_raw)['query']['general']['git-hash'],
                            decode(saved[site_info.SNAPSHOT])['query']['general'].get('git-hash')):
                        raise ValueError('Defaults and Figure observations use different source versions')
                    if resume_path is not None:
                        if small(root / ROLES['figure-sizing-site'], MAX_RESPONSE) != site_raw:
                            raise ValueError('Accepted first lean response changed before continuation')
                    else:
                        evidence.put(root / ROLES['figure-sizing-site'], site_raw)
                        header = {'schema': RAW_STREAM_SCHEMA, 'wiki': args.wiki,
                            'core_revision': decode(site_raw)['query']['general']['git-hash'],
                            'namespace_registry_sha256': digest(namespace), 'records_count': len(desired),
                            'base_batches': base_count, 'observed_batches': observed_count,
                            'record_encoding': RAW_RECORD_ENCODING}
                        raw_output.write(stream_encoded(header))
                raw_output.write(line)
                request_output.write(stream_encoded(source))
                raw_output.flush(); os.fsync(raw_output.fileno())
                request_output.flush(); os.fsync(request_output.fileno())
                # Only the newly owned accepted duplicate is retired after its
                # exact bytes and receipt have a durable place in the raw role.
                if accepted_path is not None:
                    accepted_paths.append((accepted_path, accepted_stamp))
                for path, expected_stamp in accepted_paths:
                    if evidence.stamp(path) != expected_stamp:
                        raise ValueError('Accepted HTTP response changed before archival retirement')
                for path, _ in accepted_paths:
                    path.unlink()
                count += 1
                replay_source(root, source, batch, args.wiki, args.date, namespace, http_files, prefix_cache, profile_kind=profile_kind, inventory_cache=inventory_cache, allow_compatible_epochs=True, origin_plan=plan)
                yield batch
            if total == 0:
                evidence.put(root / ROLES['figure-sizing-site'], site_raw)
                raw_output.write(stream_encoded({'schema': RAW_STREAM_SCHEMA, 'wiki': args.wiki,
                    'core_revision': decode(site_raw)['query']['general']['git-hash'],
                    'namespace_registry_sha256': digest(namespace), 'records_count': 0,
                    'base_batches': 0, 'observed_batches': 0, 'record_encoding': RAW_RECORD_ENCODING}))
    try:
        batches = iterator()
        # The first response establishes the exact API epoch for the shared
        # source profile; the reducer validates each batch before requesting next.
        first = next(batches, None)
        document = file_records(itertools.chain(() if first is None else (first,), batches),
            namespace, args.wiki, args.date, site_raw, has_batches=bool(base_count), record_limit=len(desired),
            profile_kind=profile_kind, **replay_policy)
        if slots is not None and (error := slots.close()) is not None:
            raise error
        if not figure_source_compatible(document['core_revision'], decode(saved[site_info.SNAPSHOT])['query']['general'].get('git-hash')):
            raise ValueError('Defaults and Figure observations use different source versions')
        check_prefix_cache(prefix_cache)
        raw_id = evidence.fingerprint(raw_path)
        document.update(schema=FILES_STREAM_SCHEMA, records_count=len(document['records']),
            raw_bytes=raw_id['size'], raw_sha256=raw_id['sha256'], generator_sha256=producer()['generator_sha256'], replay_contract=target_contract)
        coverage = file_coverage(document, inventory, query_titles)
        write_projection_stream(root / ROLES['figure-sizing'], document)
        with (root / PROVIDER).open('xb') as output:
            for chunk in provider_chunks(document):
                output.write(chunk)
        # Selection and both serializations are finished. The independent final
        # replay needs ancestor proofs, not either retained record graph.
        del document
        for cache_key, complete in prefix_cache.items():
            if type(cache_key) is tuple and len(cache_key) == 2 and cache_key[0] == 'complete-stream':
                complete.pop('document', None)
        manifest = {'schema': SCHEMA, 'capture_format': FILES_STREAM_SCHEMA,
            **producer(), 'wiki': args.wiki, 'date': args.date,
            'namespace_registry_sha256': defaults['namespace_registry_sha256'], 'coverage': coverage,
            'artifacts': payload(root), 'resumes': resumes,
            'source_dump_files': [{**{key: row[key] for key in ('wiki', 'date', 'name', 'size', 'sha1')},
                                   'url': 'https://dumps.wikimedia.org'+row['url']}
                                  for row in inventory['sources']],
            'outputs': {role: evidence.fingerprint(root / name)['sha256'] for role, name in output_roles(root).items()}}
        evidence.document(root / MANIFEST, manifest)
        if _verification_caches is not None:
            def output_state():
                members, directories = capture_member_paths(root, include_markers=True)
                return ({path: evidence.stamp(path) for path in members.values()},
                        {path: (*stamp, path.stat().st_uid, path.stat().st_gid)
                         for path, stamp in directories.items()})
            before_output = output_state()
            if root / COMPLETE in before_output[0]:
                raise ValueError('Figure capture completion appeared before validation')
        verify(root, require_complete=False, retained_cache=prefix_cache, inventory_cache=inventory_cache)
        if _verification_caches is not None and output_state() != before_output:
            raise ValueError('Figure capture output changed during final validation')
        evidence.document(root / COMPLETE, {'schema': SCHEMA, 'manifest_sha256': digest(small(root / MANIFEST))})
        if _verification_caches is not None:
            published_output = output_state()
            files_before, dirs_before = before_output
            files_after, dirs_after = published_output
            # Only our COMPLETE insertion may advance the root's directory times.
            if (set(files_after) != set(files_before) | {root / COMPLETE} or
                    any(files_after[path] != value for path, value in files_before.items()) or
                    dirs_after.keys() != dirs_before.keys() or
                    any((dirs_after[path][:3] + dirs_after[path][5:] != value[:3] + value[5:])
                        if path == root else dirs_after[path] != value
                        for path, value in dirs_before.items())):
                raise ValueError('Figure capture output changed during completion publication')
            def check_output():
                if output_state() != published_output:
                    raise ValueError('Completed Figure capture output changed')
            _verification_caches['output_check'] = check_output
        return manifest
    except BaseException as original:
        if slots is not None:
            original = slots.close(original) or original
        try:
            batches.close()
            if lean and count == 0 and str(original) in WALL_ERRORS and not (root/ROLES['figure-sizing-site']).exists():
                accepted = []
                for attempt in range(1, 5):
                    receipt_name = f'file-metadata.response-000001-{attempt:02d}.receipt.json'
                    if (root/receipt_name).exists() and decode(small(root/receipt_name)).get('accepted') is True:
                        accepted.append({'request': 'file-metadata.request-000001.json', 'accepted_receipt': receipt_name})
                if len(accepted) == 1:
                    names, raw, _, _ = captured_http_stage(root, accepted[0], args.wiki, light=True)
                    lean_tiff_titles({'requests': names, 'response': raw.decode('utf-8')},
                                     namespace, args.wiki, args.date, profile_kind, allow_compatible_epochs=True)
                    if not figure_source_compatible(decode(raw)['query']['general']['git-hash'],
                            decode(saved[site_info.SNAPSHOT])['query']['general'].get('git-hash')):
                        raise ValueError('First accepted lean response changed default source family')
                    if small(request_path) != stream_encoded({'schema': REQUEST_STREAM_SCHEMA, 'batches': total}):
                        raise ValueError('Empty lean prefix has uncommitted request records')
                    evidence.put(root/ROLES['figure-sizing-site'], raw)
                    with append_prefix(raw_path, 0) as output:
                        output.write(stream_encoded({'schema': RAW_STREAM_SCHEMA, 'wiki': args.wiki,
                            'core_revision': decode(raw)['query']['general']['git-hash'],
                            'namespace_registry_sha256': digest(namespace), 'records_count': len(desired),
                            'base_batches': base_count, 'observed_batches': observed_count,
                            'record_encoding': RAW_RECORD_ENCODING}))
                        output.flush();os.fsync(output.fileno())
            number = len(resumes)+1
            failure_name = f'figure-failure-{number:04d}.json'
            failure = {'error': str(original), 'source': capture_source(),
                'plan_sha256': digest(encoded(plan)), 'committed_batches': count,
                'artifacts': payload(root), 'resumes': resumes}
            if slots is not None or lean:
                committed_http = max(0, min(count-len(retained), len(planned)))
                # A resumed head may stop before its authenticated lookahead is
                # queued again. Its retained evidence still occupies that slot.
                pending_numbers = (set(slots.pending) if slots is not None else {committed_http+1}) | set(pending_http)
                failure['pending_http'] = sorted(number for number in pending_numbers
                    if number > committed_http and f'file-metadata.request-{number:06d}.json' in failure['artifacts'])
            evidence.document(root / failure_name, failure)
        except BaseException as save_error:
            original.add_note('Could not preserve Figure capture failure: '+str(save_error))
        raise original


def select_reuse_batches(paths, wiki, date, namespace):
    """Authenticate explicit records, then scope them by captured wiki and date."""
    if not isinstance(paths, (tuple, list)):
        raise ValueError('Invalid explicit Figure batch selection')
    selected, locators, documents, requested, observed, facts, cores = [], set(), set(), {}, set(), {}, {}
    height_keys = set()
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
        is_prefix = record.get('schema') in CLOSED_PREFIX_SCHEMAS
        is_complete = record.get('schema') == SCHEMA and record.get('capture_format') == FILES_STREAM_SCHEMA
        if is_complete:
            complete = read_complete_capture(path, prefix_cache)
            own_namespace, result = complete['namespace'], complete['document']
            supplement = False
            width_supplement = False
        elif is_prefix:
            prefix = read_closed_prefix(path, prefix_cache)
            own_namespace, result = prefix['namespace'], prefix['document']
            supplement = False
            width_supplement = False
        else:
            own_namespace = small(path.parent / metadata.NAMESPACE)
            evidence.Registry(own_namespace, record_wiki, record_date)
            batch = retained_metadata_batch(path, record_wiki, record_date, own_namespace)
            plain = {'requests': batch['requests'], 'response': batch['response']}
            height_supplement = 'observed_svg_occurrences' in batch
            jpeg_supplement = 'jpeg_metadata_only' in batch
            result = file_records((plain, batch) if height_supplement else (plain,), own_namespace, record_wiki, record_date,
                                  batch['response'].encode(), has_batches=True, record_limit=50,
                                  profile_kind=FIGURE_PROFILE_V4 if height_supplement or jpeg_supplement else FIGURE_PROFILE_V3, allow_compatible_epochs=jpeg_supplement)
            width_supplement = 'observed_svg_width_px' in batch
            supplement = width_supplement or height_supplement or jpeg_supplement
        group = (record_wiki, record_date)
        if cores.setdefault(group, result['core_revision']) != result['core_revision']:
            raise ValueError('Explicit Figure batches mix source versions')
        source_observed = set()
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
            if (width_supplement or 'observed_svg_width_px' in row) and canonical not in source_observed:
                if canonical in observed:
                    raise ValueError('Duplicate explicit observed Figure authority')
                observed.add(canonical)
                source_observed.add(canonical)
            for value in row.get('observed_svg_heights', []):
                occurrence = (*group, row['canonical_file'], value['title'], value['options'], value['height_px'])
                if occurrence in height_keys:
                    raise ValueError('Duplicate explicit SVG occurrence authority')
                height_keys.add(occurrence)
        if small(path) != raw:
            raise ValueError('Explicit Figure batch changed during authentication')
        if record_wiki != wiki:
            continue
        if record_date != date or own_namespace != namespace:
            raise ValueError('Explicit Figure batch differs from the selected edition namespace/date')
        selected.append({'kind': 'complete-stream' if is_complete else 'closed-prefix' if is_prefix else 'retained-request', 'path': str(path), 'sha256': sha})
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
    actual = plan['retained'] + plan['observed'] + plan.get('closed_prefixes', []) + plan.get('complete_captures', [])
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
    selected_profile = FIGURE_PROFILE_V3
    selected_mode = 'full'
    if resume is not None:
        resumed_plan = inventory_document(generation/PLAN)
        selected_mode = resumed_plan.get('metadata_mode', 'full')
        selected_profile = resumed_plan.get('figure_profile', FIGURE_PROFILE_V3)
    for reference in retained:
        path = Path(reference['path'])
        if digest(small(path)) != reference['sha256']:
            raise ValueError('Selected Figure batch changed before preparation')
        if reference['kind'] == 'closed-prefix':
            prefix = read_closed_prefix(path)
            selected_mode = prefix['plan'].get('metadata_mode', 'full')
            names_selected = {row['requested_file'] for row in prefix['document']['records']} | set(prefix['failed_titles'])
            inherited = (prefix['document']['source_profile'] or {}).get('kind')
            if inherited == FIGURE_PROFILE_V5 or (inherited == FIGURE_PROFILE_V4 and selected_profile != FIGURE_PROFILE_V5):
                selected_profile = inherited
        elif reference['kind'] == 'complete-stream':
            complete = read_complete_capture(path)
            names_selected = {row['requested_file'] for row in complete['document']['records']}
            inherited = (complete['document']['source_profile'] or {}).get('kind')
            if inherited == FIGURE_PROFILE_V5 or (inherited == FIGURE_PROFILE_V4 and selected_profile != FIGURE_PROFILE_V5):
                selected_profile = inherited
        else:
            batch = retained_metadata_batch(path, wiki, date, namespace_raw)
            names_selected = set(batch['requests'])
            if 'observed_svg_occurrences' in batch and selected_profile != FIGURE_PROFILE_V5:
                selected_profile = FIGURE_PROFILE_V4
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
        wall_seconds=86400, resume=resume, figure_profile=selected_profile, max_inflight=2, metadata_mode=selected_mode,
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



# This is the versioned offline form of the existing capture plan, not a new
# raw-frame encoding. Legacy verifiers reject its unknown metadata_mode.
MATERIALIZED_HTTP_MODE = 'materialized-http-origins-v1'


def materialized_local_file(root, reference):
    if not isinstance(reference, dict) or set(reference) != {'path', 'bytes', 'sha256'}:
        raise ValueError('Invalid materialized Figure artifact descriptor')
    value = reference['path']
    if not isinstance(value, str):
        raise ValueError('Invalid materialized Figure artifact path')
    pieces = value.split('/')
    if not 1 <= len(pieces) <= 2:
        raise ValueError('Materialized Figure artifact escaped its origin')
    for piece in pieces:
        observed_artifact_name(piece)
    if len(pieces) == 2 and re.fullmatch(r'figure-origin-[0-9a-f]{64}', pieces[0]) is None:
        raise ValueError('Invalid materialized Figure origin namespace')
    path = Path(root).absolute().joinpath(*pieces)
    if any(parent.is_symlink() for parent in (Path(root), path.parent)) or path.resolve() != path:
        raise ValueError('Unsafe materialized Figure artifact')
    before = evidence.stamp(path)
    identity = evidence.fingerprint(path)
    if (identity['size'] != reference['bytes'] or identity['sha256'] != reference['sha256'] or
            evidence.stamp(path) != before):
        raise ValueError('Materialized Figure artifact changed')
    return path


def materialized_observations(plan):
    """Keep original observation authorities separate from inherited HTTP frames."""
    rows = plan.get('observed', [])
    count = plan.get('observed_batches')
    if (type(count) is not int or count < 0 or not isinstance(rows, list) or len(rows) != count):
        raise ValueError('Invalid materialized Figure observation count')
    identities = set()
    for row in rows:
        if (not isinstance(row, dict) or set(row) != {'kind', 'path', 'sha256'} or
                row['kind'] != 'retained-request' or not isinstance(row['path'], str) or
                not Path(row['path']).is_absolute() or os.path.normpath(row['path']) != row['path'] or
                not isinstance(row['sha256'], str) or re.fullmatch('[0-9a-f]{64}', row['sha256']) is None):
            raise ValueError('Invalid materialized Figure observation authority')
        identity = (row['path'], row['sha256'])
        if identity in identities:
            raise ValueError('Duplicate materialized Figure observation authority')
        identities.add(identity)
    return rows


def materialized_origin_catalog(root, plan, wiki, date, namespace, inventory):
    rows = plan.get('materialized_http_origins')
    if (plan.get('metadata_mode') != MATERIALIZED_HTTP_MODE or not isinstance(rows, list) or
            not rows or len(rows) > 1024 or plan.get('retained') != [] or
            plan.get('closed_prefixes', []) != [] or plan.get('complete_captures', []) != []):
        raise ValueError('Invalid materialized Figure plan')
    materialized_observations(plan)
    fields = {'id', 'source_reference', 'authority_kind', 'authority', 'complete', 'closure', 'failure',
              'plan', 'journal', 'files', 'pending', 'frame_map', 'epochs'}
    nodes, references, expected = {}, {}, set()
    for row in rows:
        if not isinstance(row, dict) or set(row) != fields:
            raise ValueError('Invalid materialized Figure origin record')
        identifier = row['id']
        if (not isinstance(identifier, str) or re.fullmatch(r'figure-origin-[0-9a-f]{64}', identifier) is None or
                identifier in nodes):
            raise ValueError('Duplicate or invalid materialized Figure origin')
        source = row['source_reference']
        if (not isinstance(source, dict) or set(source) != {'kind', 'path', 'sha256'} or
                source['kind'] not in ('complete-stream', 'closed-prefix') or
                row['authority_kind'] != source['kind'] or not isinstance(source['path'], str) or
                not Path(source['path']).is_absolute() or source['sha256'] != identifier[14:]):
            raise ValueError('Unbound materialized Figure origin authority')
        key = (source['kind'], source['path'], source['sha256'])
        if key in references:
            raise ValueError('Duplicate materialized Figure source reference')
        def local(reference):
            if not reference['path'].startswith(identifier + '/'):
                raise ValueError('Materialized Figure metadata belongs to another origin')
            result = materialized_local_file(root, reference)
            expected.add(reference['path'])
            return result
        authority_path = local(row['authority'])
        if row['authority']['sha256'] != source['sha256']:
            raise ValueError('Materialized Figure authority hash differs')
        authority = decode(small(authority_path))
        origin_plan = decode(small(local(row['plan'])))
        journal_path = local(row['journal'])
        if (origin_plan.get('schema') != 'wikidict.figure-capture-plan.v1' or
                origin_plan.get('wiki') != wiki or origin_plan.get('date') != date or
                origin_plan.get('metadata_mode', 'full') not in ('full', 'lean-tiff-v1', MATERIALIZED_HTTP_MODE) or
                origin_plan.get('namespace_registry_sha256') != digest(namespace) or
                origin_plan.get('inventory_sha256') != digest(encoded(inventory)) or
                origin_plan.get('defaults') != plan.get('defaults') or
                type(origin_plan.get('base_batches')) is not int or origin_plan['base_batches'] < 0 or
                type(origin_plan.get('records_count')) is not int or origin_plan['records_count'] < 0 or
                type(origin_plan.get('batch_size')) is not int or not 1 <= origin_plan['batch_size'] <= 50 or
                type(origin_plan.get('observed_batches')) is not int or origin_plan.get('observed_batches') < 0):
            raise ValueError('Materialized Figure origin input or mode differs')
        materialized_observations(origin_plan)
        if (not isinstance(row['files'], dict) or not isinstance(row['pending'], list) or
                len(row['pending']) > 2 or not isinstance(row['frame_map'], list) or
                any(type(number) is not int or number < 0 for number in row['frame_map']) or
                row['frame_map'] != sorted(set(row['frame_map'])) or
                not isinstance(row['epochs'], list) or row['epochs'] != sorted(set(row['epochs'])) or
                any(not isinstance(core, str) or figure_profile(core,origin_plan.get('figure_profile',FIGURE_PROFILE_V3)) is None for core in row['epochs'])):
            raise ValueError('Invalid materialized Figure origin source echo')
        failure, closure, proof = None, None, None
        if source['kind'] == 'complete-stream':
            if (authority.get('schema') != SCHEMA or authority.get('capture_format') != FILES_STREAM_SCHEMA or
                    authority.get('wiki') != wiki or authority.get('date') != date or
                    authority.get('namespace_registry_sha256') != digest(namespace) or
                    authority.get('resumes', []) != [] or
                    row['complete'] is None or row['closure'] is not None or row['failure'] is not None or row['pending']):
                raise ValueError('Invalid materialized complete Figure authority')
            if decode(small(local(row['complete']))) != {'schema': SCHEMA, 'manifest_sha256': source['sha256']}:
                raise ValueError('Materialized complete Figure marker differs')
            expected_sources = [{key:item[key] for key in ('wiki','date','name','url','size','sha1')}
                                for item in inventory['sources']]
            for item in expected_sources:item['url']='https://dumps.wikimedia.org'+item['url']
            if authority.get('source_dump_files') != expected_sources:
                raise ValueError('Materialized Figure origin dump selection differs')
            artifacts = authority.get('artifacts')
            committed = origin_plan['base_batches'] + origin_plan['observed_batches']
        else:
            proof = authority
            if (proof.get('schema') not in CLOSED_PREFIX_SCHEMAS or proof.get('wiki') != wiki or
                    proof.get('date') != date or row['complete'] is not None or
                    row['closure'] is None or row['failure'] is None):
                raise ValueError('Invalid materialized closed Figure authority')
            closure_path = local(row['closure']); closure = decode(small(closure_path))
            if ({k:row['closure'][k] for k in ('bytes', 'sha256')} !=
                    {k:proof['closure'][k] for k in ('bytes', 'sha256')} or
                    closure.get('outcome') != 'FAILED-PHYSICALLY-SOURCE-CLOSED' or
                    any(closure.get(k) is not True for k in
                        ('source_after', 'reaped', 'dual_proc_absence', 'ps_absence', 'allocation_released')) or
                    type(closure.get('terminal')) is not int or closure['terminal'] == 0):
                raise ValueError('Materialized Figure origin lacks exact closure')
            failure = decode(small(local(row['failure'])))
            if (failure.get('plan_sha256') != digest(encoded(origin_plan)) or
                    failure.get('source') != origin_plan.get('source') or failure.get('resumes') != []):
                raise ValueError('Materialized Figure failure changed its plan')
            if proof['schema'] == SOURCE_PREFIX_SCHEMA:
                if set(proof)!={'schema','wiki','date','source_root','original_root','closure','source_epochs'}:
                    raise ValueError('Unknown materialized Figure source proof shape')
                for field in ('source_root','original_root'):
                    value=proof[field]
                    if not isinstance(value,str) or not Path(value).is_absolute() or os.path.normpath(value)!=value:
                        raise ValueError('Invalid materialized Figure historical source locator')
                if not isinstance(proof['closure'],dict) or set(proof['closure'])!={'path','bytes','sha256'}:
                    raise ValueError('Invalid materialized Figure historical closure descriptor')
                refs = closure.get('retained_metadata', {})
                if not isinstance(refs,dict) or set(refs)!={'failure','plan','journal'}:
                    raise ValueError('Materialized Figure source metadata roles differ')
                for role,reference in refs.items():
                    if not isinstance(reference,dict) or set(reference)!={'path','bytes','sha256'}:
                        raise ValueError('Invalid materialized Figure original role descriptor')
                    if role in ('plan','journal') and Path(reference['path']).name!={'plan':PLAN,'journal':FILE_REQUESTS}[role]:
                        raise ValueError('Materialized Figure original metadata role changed')
                for role in ('plan', 'journal', 'failure'):
                    if (Path(refs[role]['path']).parent != Path(proof.get('original_root','')) or{k:row[role][k] for k in ('bytes', 'sha256')} !=
                            {k:refs[role][k] for k in ('bytes', 'sha256')}):
                        raise ValueError('Materialized Figure source-epoch metadata differs')
                if (closure.get('detail') != 'Lean Figure and defaults source versions differ' or
                        failure.get('error') != closure['detail'] or
                        proof.get('source_epochs') != [FIGURE_CURRENT_CORE, FIGURE_RESPONSE_CORE] or
                        origin_plan.get('metadata_mode') != 'lean-tiff-v1'):
                    raise ValueError('Materialized Figure source epoch is unreviewed')
            elif (closure.get('capture_root') != proof.get('original_root') or
                    failure.get('error') != 'Oversized API response' or
                    closure.get('capture_plan_sha256') != digest(encoded(origin_plan)) or
                    {k:row['failure'][k] for k in ('bytes', 'sha256')} !=
                    {k:closure['capture_failure'][k] for k in ('bytes', 'sha256')}):
                raise ValueError('Materialized oversized Figure origin differs')
            artifacts = failure.get('artifacts')
            committed = failure.get('committed_batches')
            if closure.get('committed_batches') != committed:
                raise ValueError('Materialized Figure committed prefix differs')
        if origin_plan.get('figure_profile', FIGURE_PROFILE_V3) not in (FIGURE_PROFILE_V3, FIGURE_PROFILE_V4):
            raise ValueError('Unknown materialized Figure source profile')
        if proof is not None and proof['schema']==CLOSED_PREFIX_SCHEMA:
            for role in ('actual_request','actual_receipt','actual_response'):
                reference=closure.get(role,{})
                name=Path(reference.get('path','')).name
                if (Path(reference.get('path','')).parent!=Path(proof.get('original_root','')) or
                        name not in row['files'] or
                        {k:row['files'][name][k] for k in ('bytes','sha256')}!={k:reference[k] for k in ('bytes','sha256')}):
                    raise ValueError('Materialized oversized Figure evidence is unbound')
            request=decode(small(materialized_local_file(root,row['files'][Path(closure['actual_request']['path']).name])))
            receipt=decode(small(materialized_local_file(root,row['files'][Path(closure['actual_receipt']['path']).name])))
            titles=request.get('titles'); light=proof.get('light_titles')
            if (not isinstance(titles,list) or not 1<=len(titles)<=50 or len(set(titles))!=len(titles) or
                    request!={'titles':titles,'query':metadata.query_for(wiki,titles,figure_axes=True),'url':metadata.query_url(wiki,titles,figure_axes=True)} or
                    not isinstance(light,list) or not light or len(set(light))!=len(light) or not set(light)<=set(titles) or
                    receipt.get('request')!=Path(closure['actual_request']['path']).name or
                    receipt.get('response')!=Path(closure['actual_response']['path']).name or receipt.get('status')!=200 or
                    receipt.get('accepted') is not False or receipt.get('api_error_code') is not None or receipt.get('error')!='Oversized API response' or
                    receipt.get('response_bytes')!=MAX_RESPONSE+1 or
                    receipt.get('response_sha256')!=closure['actual_response']['sha256'] or
                    closure['actual_response']['bytes']!=MAX_RESPONSE+1):
                raise ValueError('Materialized Figure metadata-light exception changed')
        if not isinstance(artifacts, dict) or type(committed) is not int or committed < 0:
            raise ValueError('Invalid materialized Figure artifact authority')
        for name, reference in row['files'].items():
            observed_artifact_name(name)
            if name in (ROLES['figure-sizing-raw'], ROLES['figure-sizing'], PROVIDER):
                raise ValueError('Materialized origin retained a predecessor payload')
            if name not in artifacts or {k:reference[k] for k in ('bytes', 'sha256')} != artifacts[name]:
                raise ValueError('Materialized Figure artifact lacks original byte authority')
            if not reference['path'].startswith(identifier + '/') and reference['path'] != name:
                raise ValueError('Materialized shared Figure artifact aliases another role')
            materialized_local_file(root, reference); expected.add(reference['path'])
        for name, reference in ((PLAN,row['plan']), (FILE_REQUESTS,row['journal'])):
            if artifacts.get(name) != {k:reference[k] for k in ('bytes','sha256')}:
                raise ValueError('Materialized Figure plan/journal lost original byte binding')
        with journal_path.open('rb') as stream:
            header = stream_decode(stream.readline(STREAM_HEADER_LIMIT+1))
            if header != {'schema':REQUEST_STREAM_SCHEMA, 'batches':origin_plan['base_batches']+origin_plan['observed_batches']}:
                raise ValueError('Materialized Figure journal header differs')
            sources = []
            for _ in range(committed):
                line = stream.readline(STREAM_HEADER_LIMIT+1)
                if not line or len(line)>STREAM_HEADER_LIMIT:
                    raise ValueError('Truncated materialized Figure source journal')
                sources.append(stream_decode(line))
            if stream.read(1):
                raise ValueError('Uncommitted materialized Figure journal evidence')
        if len(row['frame_map']) != committed+len(row['pending']):
            raise ValueError('Materialized Figure frame count differs')
        query = row['files'].get(QUERY_INPUTS)
        if query is None or decode(small(materialized_local_file(root,query))) != origin_plan.get('query_inputs'):
            raise ValueError('Materialized Figure query inputs differ')
        # Keep original query basenames in the origin: the normal query parser
        # authenticates the same per-origin files without rebasing their bytes.
        own_root = Path(root)/identifier
        desired = set(inventory['titles']) | provider_query_titles(own_root, origin_plan['query_inputs'], namespace, wiki, date)
        if len(desired) != origin_plan.get('records_count'):
            raise ValueError('Materialized Figure origin inventory count differs')
        node=dict(row=row, plan=origin_plan, authority=authority, proof=proof, closure=closure,
                  failure=failure, artifacts=artifacts, committed=committed,
                  sources=sources+row['pending'], desired=desired, own_root=own_root)
        nodes[identifier]=node; references[key]=identifier
    root_id = plan.get('materialized_root')
    if root_id not in nodes or nodes[root_id]['row']['authority_kind'] != 'complete-stream':
        raise ValueError('Materialized Figure plan lacks its original complete root')
    return dict(nodes=nodes,references=references,expected=expected,root=root_id,frames=[],
                capture_root=Path(root),inventory=inventory)


def materialized_frame_echo(state, source, batch, archived, root):
    if source.get('kind') == 'retained-request':
        # replay_source already verified the exact original record and all its
        # artifacts. Observations retain that authority; they are not HTTP origins.
        core=decode(batch['response'].encode()).get('query',{}).get('general',{}).get('git-hash')
        state['frames'].append(dict(source=source,requests=batch['requests'],core=core,virtual={}))
        return
    reference = source.get('batch', {}).get('accepted_receipt', '')
    pieces = reference.split('/')
    if len(pieces)!=2 or pieces[0] not in state['nodes']:
        raise ValueError('Unbound materialized Figure HTTP frame')
    identifier=pieces[0]
    receipt=decode(small(Path(root)/reference))
    response_key=identifier+'/'+receipt['response']
    if response_key not in archived:
        raise ValueError('Materialized Figure frame lacks durable HTTP echo')
    core=decode(batch['response'].encode()).get('query',{}).get('general',{}).get('git-hash')
    if figure_profile(core,state['nodes'][identifier]['plan'].get('figure_profile',FIGURE_PROFILE_V3)) is None:
        raise ValueError('Unknown materialized Figure response epoch')
    virtual={receipt['response']:archived[response_key]}
    if 'tiff_batch' in source:
        receipt=decode(small(Path(root)/source['tiff_batch']['accepted_receipt']))
        virtual[receipt['response']]=archived[identifier+'/'+receipt['response']]
    state['frames'].append(dict(source=source,requests=batch['requests'],core=core,virtual=virtual))


def validate_materialized_echo(state, plan, wiki, date, namespace, *, root_record_count=None, verified_batches=None, wrapper_ancestors=frozenset()):
    frames=state['frames']; nodes=state['nodes']; references=state['references']; reached=set(); active=set()
    if state['root'] in wrapper_ancestors or len(wrapper_ancestors) >= 64:
        raise ValueError('Cyclic or excessive materialized wrapper ancestry')
    if nodes[state['root']]['row']['frame_map'] != list(range(len(frames))):
        raise ValueError('Materialized Figure root omits or reorders raw frames')
    original=nodes[state['root']]['plan']
    if any(plan.get(key) != original.get(key) for key in ('base_batches','observed_batches','observed')):
        raise ValueError('Materialized Figure inherited/observation partition changed')
    observed=materialized_observations(plan)
    if ([frame['source'] for frame in frames[plan['base_batches']:]] != observed or
            len(frames) != plan['base_batches']+len(observed)):
        raise ValueError('Materialized Figure observation partition differs')
    def referenced(source):
        if not isinstance(source,dict) or set(source)!={'kind','path','sha256','batch'}:
            raise ValueError('Unresolved materialized Figure ancestry')
        key=(source['kind'],source['path'],source['sha256'])
        if key not in references or type(source['batch']) is not int:
            raise ValueError('Unbound materialized Figure predecessor')
        return references[key]
    def scope(identifier, source):
        result=dict(source)
        for key in ('batch','tiff_batch'):
            if key in result:result[key]={name:identifier+'/'+value for name,value in result[key].items()}
        for key in ('artifacts','tiff_artifacts'):
            if key in result:result[key]=[identifier+'/'+value for value in result[key]]
        return result
    def ordinary_origin(identifier, node, row, old, sources):
        retained=old.get('retained')
        observed=materialized_observations(old)
        if (sources[:node['committed']][old['base_batches']:] != observed or
                (node['failure'] is None and node['committed'] != old['base_batches']+len(observed))):
            raise ValueError('Materialized original observation partition differs')
        if (not isinstance(retained,list) or sources[:len(retained)]!=retained or
                len(retained)>node['committed'] or any(n>=len(frames) for n in row['frame_map'])):
            raise ValueError('Materialized Figure retained source order differs')
        for kind, field in (('complete-stream','complete_captures'),('closed-prefix','closed_prefixes')):
            declared=old.get(field,[])
            if not isinstance(declared,list) or len(declared)>1:
                raise ValueError('Invalid materialized original predecessor selection')
            required=[]
            for reference in declared:
                if not isinstance(reference,dict) or set(reference)!={'kind','path','sha256'} or reference['kind']!=kind:
                    raise ValueError('Invalid materialized original predecessor reference')
                other=referenced(dict(reference,batch=0))
                if kind=='complete-stream':
                    predecessor=nodes[other]['plan']['query_inputs']
                    if old['query_inputs'][:len(predecessor)]!=predecessor:
                        raise ValueError('Materialized original query-input prefix differs')
                required.extend(dict(reference,batch=slot) for slot in range(len(nodes[other]['row']['frame_map'])))
            actual=[item for item in sources if item.get('kind')==kind]
            if actual!=required:
                raise ValueError('Materialized original predecessor selection differs from journal')
        retained_names=set()
        for number in row['frame_map'][:len(retained)]:
            names=set(frames[number]['requests'])
            if names & retained_names:raise ValueError('Duplicate materialized retained requests')
            retained_names.update(names)
        remaining=sorted(node['desired']-retained_names,key=lambda name:name.encode())
        del retained_names
        planned=list(metadata.title_batches(wiki,remaining,old['batch_size'],figure_axes=True))
        del remaining
        light=set()
        for ref in old.get('closed_prefixes',[]):
            other=referenced(dict(ref,batch=0)); proof=nodes[other]['proof']
            if proof is None:raise ValueError('Materialized light scope lacks closed-prefix proof')
            light.update(proof.get('light_titles',[]))
        mode=old.get('metadata_mode','full')
        if mode=='full' and light:
            split=[]
            for titles in planned:
                ordinary=[title for title in titles if title not in light]
                if ordinary:split.append(ordinary)
                split.extend([title] for title in titles if title in light)
            planned=split
        if (old.get('planned_requests_sha256')!=digest(encoded(planned)) or
                old['base_batches']!=len(retained)+len(planned) or
                old.get('metadata_light_titles',[])!=sorted(light,key=lambda name:name.encode())):
            raise ValueError('Materialized Figure original request plan changed')
        own_epochs=set(); pending_numbers=[]
        for index,(source,number) in enumerate(zip(sources,row['frame_map'],strict=True)):
            frame=frames[number]
            if index >= old['base_batches'] and index < node['committed']:
                if source != observed[index-old['base_batches']] or frame['source'] != source:
                    raise ValueError('Materialized original observation identity differs')
                own_epochs.add(frame['core'])
                continue
            if source.get('kind') in ('complete-stream','closed-prefix'):
                other=referenced(source); visit(other)
                slot=source['batch']; mapping=nodes[other]['row']['frame_map']
                if not 0<=slot<len(mapping) or mapping[slot]!=number:
                    raise ValueError('Materialized Figure ancestor source echo differs')
                continue
            if source.get('kind') not in ('http-archived','http-archived-light','http-archived-lean'):
                raise ValueError('Unresolved materialized Figure terminal authority')
            if frame['source']!=scope(identifier,source) or index<len(retained):
                raise ValueError('Materialized Figure terminal source echo differs')
            n=index-len(retained)+1
            if (index>=node['committed'] and node['proof'] is not None and
                    node['proof']['schema']==CLOSED_PREFIX_SCHEMA):
                n+=1  # The rejected oversized request precedes the accepted second slot.
            if not 1<=n<=len(planned) or frame['requests']!=planned[n-1]:
                raise ValueError('Materialized Figure accepted request order changed')
            expected_kind=('http-archived-lean' if mode=='lean-tiff-v1' else
                           'http-archived-light' if set(frame['requests'])<=light else 'http-archived')
            if source['kind']!=expected_kind:
                raise ValueError('Materialized Figure origin mode was relabelled')
            match=re.fullmatch(r'file-metadata\.response-(\d{6})-(\d{2})\.receipt\.json',source['batch']['accepted_receipt'])
            if match is None or int(match[1])!=n:
                raise ValueError('Materialized Figure HTTP numbering changed')
            for key in ('artifacts','tiff_artifacts'):
                for name in source.get(key,[]):
                    if name not in row['files'] or row['files'][name]['path']!=identifier+'/'+name:
                        raise ValueError('Materialized Figure terminal artifact lost original binding')
            if index>=node['committed']:
                pending_numbers.append(n)
                for name,identity in frame['virtual'].items():
                    if node['artifacts'].get(name)!=identity:
                        raise ValueError('Materialized pending response differs from accepted original bytes')
            own_epochs.add(frame['core'])
        if row['epochs']!=sorted(own_epochs):
            raise ValueError('Materialized Figure origin epochs changed')
        return pending_numbers, retained, planned
    def visit(identifier):
        if identifier in active:raise ValueError('Cyclic materialized Figure ancestry')
        if identifier in reached:return
        active.add(identifier); node=nodes[identifier]; row=node['row']; old=node['plan']; sources=node['sources']
        if old.get('metadata_mode') == MATERIALIZED_HTTP_MODE:
            # The wrapper retains its original manifest/plan/journal, while its
            # former payload is supplied by exact current frames. Importing the
            # already-contained graph must preserve every original descriptor.
            if any(number >= len(frames) for number in row['frame_map']):
                raise ValueError('Materialized wrapper frame lies outside current stream')
            nested=materialized_origin_catalog(state['capture_root'],old,wiki,date,namespace,state['inventory'])
            if sources != [frames[number]['source'] for number in row['frame_map']] or row['epochs']:
                raise ValueError('Materialized wrapper frame echo differs')
            for child_id, child in nested['nodes'].items():
                if child_id == identifier or child_id not in nodes:
                    raise ValueError('Unbound materialized wrapper origin')
                expected=dict(child['row'])
                if any(number >= len(row['frame_map']) for number in expected['frame_map']):
                    raise ValueError('Embedded materialized frame lies outside wrapper stream')
                expected['frame_map']=[row['frame_map'][number] for number in expected['frame_map']]
                if nodes[child_id]['row'] != expected:
                    raise ValueError('Materialized wrapper changed an embedded origin')
            nested['frames']=[frames[number] for number in row['frame_map']]
            def nested_batches(selected):
                numbers={row['frame_map'][number] for number in selected}
                if verified_batches is not None:
                    yield from verified_batches(numbers)
                else:
                    values=stream_values(state['capture_root']/ROLES['figure-sizing-raw'],RAW_STREAM_SCHEMA)
                    next(values)
                    for number,batch in enumerate(values):
                        if number in numbers:yield batch
            validate_materialized_echo(nested,old,wiki,date,namespace,verified_batches=nested_batches,
                wrapper_ancestors=wrapper_ancestors|{identifier})
            reached.update(nested['nodes'])
            pending_numbers=[]
        else:
            pending_numbers,retained,planned=ordinary_origin(identifier,node,row,old,sources)
        # Reproduce each original origin's semantic profile/contract, including
        # inherited frames. The current output's profile is not their authority.
        selected=set(row['frame_map'])
        def original_batches():
            if verified_batches is not None:
                yield from verified_batches(selected)
                return
            values=stream_values(Path(node['own_root']).parent/ROLES['figure-sizing-raw'],RAW_STREAM_SCHEMA)
            next(values)
            for number,batch in enumerate(values):
                if number in selected:yield batch
        source_epoch=(node['proof'] is not None and node['proof']['schema']==SOURCE_PREFIX_SCHEMA)
        if source_epoch:
            site=decode(small(Path(node['own_root'])/ROLES['figure-sizing-site'],MAX_RESPONSE))
            if (old.get('figure_profile',FIGURE_PROFILE_V3)!=FIGURE_PROFILE_V4 or
                    old.get('metadata_mode')!='lean-tiff-v1' or
                    site['query']['general'].get('git-hash')!=FIGURE_CURRENT_CORE or
                    not 0<node['committed']<old['base_batches'] or
                    not row['pending'] or
                    any(frames[number]['core']!=FIGURE_CURRENT_CORE for number in row['frame_map'][:node['committed']])):
                raise ValueError('Materialized original source epoch context differs')
        original_site=small(Path(node['own_root'])/ROLES['figure-sizing-site'],MAX_RESPONSE)
        options=dict(has_batches=bool(selected),record_limit=old['records_count'],
            profile_kind=old.get('figure_profile',FIGURE_PROFILE_V3),
            allow_tiff_companion=True,
            allow_compatible_epochs=source_epoch or old.get('replay_contract') in (REPLAY_CONTRACT_V3, REPLAY_CONTRACT_V4, REPLAY_CONTRACT),
            allow_decimal_tiff_axes=old.get('replay_contract') in (REPLAY_CONTRACT_V4, REPLAY_CONTRACT),
            allow_default_tiff_page=old.get('replay_contract') == REPLAY_CONTRACT)
        original_count=(root_record_count(original_site,**options)
            if identifier==state['root'] and root_record_count is not None else None)
        if original_count is None:
            original_document=file_records(original_batches(),namespace,wiki,date,original_site,**options)
            original_count=len(original_document['records'])
            del original_document
        if node['failure'] is None and original_count!=old['records_count']:
            raise ValueError('Materialized original semantic membership differs')
        failure=node['failure']
        if failure is not None:
            if node['proof']['schema']==SOURCE_PREFIX_SCHEMA:
                if pending_numbers!=failure.get('pending_http') or any(frames[n]['core']!=FIGURE_RESPONSE_CORE for n in row['frame_map'][node['committed']:]):
                    raise ValueError('Materialized Figure pending source epoch differs')
            else:
                failed_number=node['committed']-len(retained)+1
                ref=node['closure']['actual_request']
                request=decode(small(materialized_local_file(Path(node['own_root']).parent,row['files'][Path(ref['path']).name])))
                accepted_names={name for number in row['frame_map'] for name in frames[number]['requests']}
                if (not 1<=failed_number<=len(planned) or request['titles']!=planned[failed_number-1] or
                        set(request['titles']) & accepted_names or
                        pending_numbers not in ([],[failed_number+1]) or
                        (old.get('max_inflight')==2 and failure.get('pending_http')!=[failed_number,*pending_numbers]) or
                        (old.get('max_inflight')!=2 and pending_numbers)):
                    raise ValueError('Materialized oversized Figure lookahead differs')
        active.remove(identifier); reached.add(identifier)
    visit(state['root'])
    if reached!=set(nodes):raise ValueError('Unbound materialized Figure origin was added')
    return state['expected']


def materialize_complete_capture(source, output, *, max_batches=64, max_input_bytes=64*1024*1024,
                                 link_current_payloads=False, cleanup_failed_links=False, observations=None, phase_progress=False):
    """Offline, bounded materialization of verified stream ancestry.

    Original request/receipt bytes and per-origin plans remain immutable. The
    current raw/fact/provider roles are copied exactly once; predecessor raw and
    projection payloads are represented by terminal HTTP echoes, never copied.
    Retained observation records remain exact external source dependencies.
    Explicit linked mode shares only the four immutable current payloads and
    records each owned nlink/ctime transition; all original byte guards remain.
    The small defaults deliberately exclude production datasets unless a later
    separately admitted caller selects explicit larger bounds.
    """
    import copy
    if type(phase_progress) is not bool:
        raise ValueError('Invalid Figure phase progress selection')
    if (type(max_batches) is not int or not 0<=max_batches<=0xffffffff or
            type(max_input_bytes) is not int or max_input_bytes<=0):
        raise ValueError('Invalid offline Figure materialization bounds')
    source, output = Path(source), Path(output)
    if (not source.is_absolute() or source.name!=MANIFEST or source.resolve()!=source or
            not output.is_absolute() or output.is_symlink() or os.path.lexists(output) or
            output.resolve().is_relative_to(source.parent.resolve())):
        raise ValueError('Offline Figure materialization requires a fresh independent output')
    nodes, by_reference, active, stamps, roots = {}, {}, set(), {}, {}
    cache={}
    if (type(link_current_payloads) is not bool or type(cleanup_failed_links) is not bool or
            cleanup_failed_links and not link_current_payloads or
            observations is not None and type(observations) is not dict):
        raise ValueError('Invalid offline Figure link custody selection')
    if link_current_payloads and observations is None:
        raise ValueError('Linked Figure materialization requires explicit custody observations')
    observations = {} if observations is None else observations
    if observations:
        raise ValueError('Figure materialization observations must be fresh')
    observations.update(operation='materialize-complete', complete=False, linked_members=[],
        original_members=[],remaining_owned_links=[],removed_owned_links=[],
        source_complete_verified=False,new_output_adoption_allowed=False,failed_link_recovery_verified=False)
    active_phase=None
    def phase(name):
        nonlocal active_phase
        if not phase_progress:return
        wall,cpu=time.monotonic(),time.process_time()
        events=[]
        if active_phase is not None:
            previous,started_wall,started_cpu=active_phase
            events.append(dict(operation='materialize-complete',event='phase-end',phase=previous,
                               wall_seconds=wall-started_wall,process_cpu_seconds=cpu-started_cpu))
        if name is not None:
            events.append(dict(operation='materialize-complete',event='phase-start',phase=name))
        active_phase=(name,wall,cpu) if name is not None else None
        for event in events:
            # Progress is diagnostic only; a closed pipe must not replace a
            # validator exception or trigger failed-link cleanup.
            try:print(json.dumps(event,sort_keys=True),file=sys.stderr,flush=True)
            except (OSError,ValueError):pass
    link_names={ROLES['figure-sizing'],ROLES['figure-sizing-raw'],PROVIDER,INVENTORY}
    fields=('st_dev','st_ino','st_mode','st_uid','st_gid','st_size','st_mtime_ns','st_nlink','st_ctime_ns')
    linked={}; source_identities={}; owned_output=None
    def identity(path):
        value=Path(path).lstat()
        if not stat.S_ISREG(value.st_mode) or value.st_uid!=os.geteuid():
            raise ValueError('Linked Figure payload is not an owned regular file')
        return tuple(getattr(value,key) for key in fields)
    def stamp(value):
        return (value[0],value[1],value[5],value[6],value[8])
    def accept_owned_link(before, after):
        for path,value in source_identities.items():
            if value[:2]==before[:2]:
                if value!=before:raise ValueError('Linked Figure physical custody was already stale')
                source_identities[path]=after
        # Only this operation's measured same-inode link changes the custody
        # stamps. Raw offsets/digests and every other source remain unchanged.
        for held in [stamps,*(entry['stamps'] for entry in cache.values() if entry is not None)]:
            for path,value in held.items():
                if value[:2]==before[:2]:
                    if value!=stamp(before):
                        raise ValueError('Linked Figure source custody was already stale')
                    held[path]=stamp(after)
    def output_identity():
        value=output.lstat()
        if not stat.S_ISDIR(value.st_mode) or value.st_uid!=os.geteuid():
            raise ValueError('Figure link output directory ownership changed')
        return dict(path=str(output),device=value.st_dev,inode=value.st_ino,
                    mode=value.st_mode,uid=value.st_uid)
    def observe_link_custody(*, verified_artifacts=None):
        rows=[];remaining=[];errors=[];preserved=True
        for name in sorted(link_names):
            before=expected_links[name]
            row=dict(path=name,before=dict(zip(fields,before)),after=None,
                     sha256_before=original_manifest['artifacts'][name]['sha256'],sha256_after=None)
            rows.append(row)
            try:
                after=identity(root/name);row['after']=dict(zip(fields,after))
                if after[:7]!=before[:7]:raise ValueError('Original Figure content identity changed')
                if verified_artifacts is None:
                    source_fd=os.open(root/name,os.O_RDONLY|os.O_NOFOLLOW)
                    with os.fdopen(source_fd,'rb') as stream:
                        if tuple(getattr(os.fstat(stream.fileno()),key) for key in fields)!=after:
                            raise ValueError('Original Figure opened identity differs')
                        hashed=hashlib.sha256();size=0
                        while chunk:=stream.read(1024*1024):
                            size+=len(chunk)
                            if size>before[5]:raise ValueError('Original Figure grew during custody closure')
                            hashed.update(chunk)
                    if size!=before[5]:raise ValueError('Original Figure shrank during custody closure')
                    row['sha256_after']=hashed.hexdigest()
                else:row['sha256_after']=verified_artifacts[name]['sha256']
                if identity(root/name)!=after or row['sha256_after']!=row['sha256_before']:
                    raise ValueError('Original Figure bytes changed during custody closure')
            except (OSError,ValueError) as error:
                preserved=False;errors.append(name+': '+str(error))
            destination=output/name
            if os.path.lexists(destination):
                try:
                    actual=identity(destination)
                    remaining.append(dict(path=name,target=str(destination),stamp=dict(zip(fields,actual))))
                    if row['after']!=dict(zip(fields,actual)):
                        raise ValueError('Remaining Figure target is not the original inode')
                except (OSError,ValueError) as error:errors.append(name+': '+str(error))
        observations.update(original_members=rows,remaining_owned_links=remaining,
                            source_content_mode_inode_preserved=preserved)
        try:
            if owned_output is None or output_identity()!=owned_output:
                raise ValueError('Owned Figure output directory changed')
            check()
            touched={row['path'] for row in observations['linked_members']}
            removed={row['path'] for row in observations['removed_owned_links']}
            kept={row['path'] for row in remaining}
            if (len(touched)!=len(observations['linked_members']) or
                    len(removed)!=len(observations['removed_owned_links']) or
                    touched!=kept|removed or kept&removed):
                raise ValueError('Figure link event membership differs')
            for row in rows:
                before=row['before'];after=row['after']
                if after is None or after['st_nlink']!=before['st_nlink']+(row['path'] in kept):
                    raise ValueError('Figure source has an unowned link-count change')
        except (OSError,ValueError) as error:errors.append(str(error))
        if verified_artifacts is None and os.path.lexists(output/COMPLETE):
            errors.append('Failed Figure output retains a completion marker')
        observations['custody_errors']=errors
        observations['failed_link_recovery_verified']=preserved and not errors
        if preserved and not errors:
            by_name={row['path']:row for row in rows}
            for row in observations['linked_members']:
                row['sha256_after']=by_name[row['path']]['sha256_after']
        return preserved and not errors
    def cleanup_owned_failed_links():
        if not observe_link_custody() or os.path.lexists(output/COMPLETE):
            raise ValueError('Failed Figure links do not have safe owned cleanup custody')
        for row in list(observations['remaining_owned_links']):
            check()
            if os.path.lexists(output/COMPLETE):
                raise ValueError('Failed Figure output acquired a completion marker during cleanup')
            name=row['path'];destination=Path(row['target']);before=identity(root/name)
            if (output_identity()!=owned_output or dict(zip(fields,before))!=row['stamp'] or
                    identity(destination)!=before):
                raise ValueError('Failed Figure link changed before owned cleanup')
            destination.unlink()
            after=identity(root/name)
            observations['removed_owned_links'].append(dict(path=name,target=str(destination),
                before=dict(zip(fields,before)),after=dict(zip(fields,after))))
            if (after[:7]!=before[:7] or after[7]!=before[7]-1 or after[8]<before[8] or
                    os.path.lexists(destination)):
                raise ValueError('Failed Figure owned cleanup changed source custody')
            accept_owned_link(before,after);linked.pop(root/name)
    def saved(path, maximum=max_input_bytes):
        path=Path(path);before=evidence.stamp(path)
        if before[2]>maximum:raise ValueError('Offline Figure fixture/input bound exceeded')
        raw=small(path,maximum)
        if evidence.stamp(path)!=before:raise ValueError('Offline Figure source changed')
        stamps[path]=before
        return raw
    def check():
        if any(identity(path)!=expected for path,expected in source_identities.items()):
            raise ValueError('Figure source changed outside its owned hard links')
        for path,(destination,expected) in linked.items():
            if identity(path)!=expected or identity(destination)!=expected:
                raise ValueError('Figure payload changed outside its owned hard link')
        check_prefix_cache(cache)
        if any(evidence.stamp(path)!=before for path,before in stamps.items()):
            raise ValueError('Offline Figure metadata changed during materialization')
        for root,(members,directory) in roots.items():
            if set(root.iterdir())!=members or complete_capture_directory_stamp(root)!=directory:
                raise ValueError('Offline Figure source membership changed')
    def journal(root, plan, committed):
        raw=saved(root/FILE_REQUESTS)
        lines=raw.splitlines(keepends=True)
        if (not lines or len(lines)!=committed+1 or
                stream_decode(lines[0])!={'schema':REQUEST_STREAM_SCHEMA,'batches':plan['base_batches']+plan['observed_batches']}):
            raise ValueError('Offline Figure original journal is incomplete')
        if any(len(line)>STREAM_HEADER_LIMIT for line in lines):
            raise ValueError('Offline Figure source record exceeds its bound')
        return [stream_decode(line) for line in lines[1:]]
    def terminal_pending(root, reference, wiki, *, lean):
        if lean:
            titles,raw,names,accepted=captured_http_stage(root,reference['base'],wiki,light=True)
            result={'kind':'http-archived-lean','batch':reference['base'],'artifacts':names}
            if 'tiff' in reference:
                _,other,tiff_names,tiff_accepted=captured_http_stage(root,reference['tiff'],wiki,light=False,stage='tiff')
                result.update(tiff_batch=reference['tiff'],tiff_artifacts=tiff_names)
            return result
        titles,raw,names,accepted=captured_http_stage(root,reference,wiki,light=False)
        return {'kind':'http-archived','batch':reference,'artifacts':names}
    def load(reference):
        key=(reference['kind'],reference['path'],reference['sha256'])
        if key in active:raise ValueError('Cyclic offline Figure ancestry')
        if key in by_reference:return by_reference[key]
        if len(nodes)>=64:raise ValueError('Offline Figure origin bound exceeded')
        active.add(key)
        path=Path(reference['path']);authority_raw=saved(path)
        if digest(authority_raw)!=reference['sha256']:raise ValueError('Offline Figure authority changed')
        authority=decode(authority_raw)
        if reference['kind']=='complete-stream':
            if authority.get('resumes', []) != []:
                raise ValueError('Unresolved offline Figure resume authority')
            root=path.parent
        elif reference['kind']=='closed-prefix' and authority.get('schema') in CLOSED_PREFIX_SCHEMAS:
            root=Path(authority['source_root'])
        else:raise ValueError('Unresolved offline Figure ancestry')
        if root.is_symlink() or root.resolve()!=root or not root.is_dir():
            raise ValueError('Unsafe offline Figure source root')
        if output.resolve().is_relative_to(root):raise ValueError('Offline Figure output aliases its ancestor')
        if evidence.stamp(root/ROLES['figure-sizing-raw'])[2]>max_input_bytes:
            raise ValueError('Offline Figure fixture/input bound exceeded')
        plan=decode(saved(root/PLAN))
        observations=materialized_observations(plan)
        if (plan.get('metadata_mode','full') not in ('full','lean-tiff-v1',MATERIALIZED_HTTP_MODE) or
                type(plan.get('base_batches')) is not int or plan['base_batches']<0 or
                plan['base_batches']+len(observations)>max_batches):
            raise ValueError('Unresolved or oversized offline Figure source plan')
        roots[root]=(set(root.iterdir()),complete_capture_directory_stamp(root))
        identifier='figure-origin-'+reference['sha256']
        if identifier in nodes:raise ValueError('Offline Figure origin has multiple unresolved aliases')
        if reference['kind']=='complete-stream':
            committed=plan['base_batches']+len(observations);pending=[];closure_path=None;failure_path=None
            artifacts=authority['artifacts']
        else:
            closure_path=Path(authority['closure']['path']);closure=decode(saved(closure_path))
            if authority['schema']==SOURCE_PREFIX_SCHEMA:
                failure_path=root/Path(closure['retained_metadata']['failure']['path']).name
            else:
                failure_path=root/Path(closure['capture_failure']['path']).name
            pending=[]
            failure=decode(saved(failure_path));committed=failure['committed_batches'];artifacts=failure['artifacts']
        sources=journal(root,plan,committed)
        node=dict(identifier=identifier,reference=dict(reference),path=path,root=root,authority=authority,
                  authority_raw=authority_raw,plan=plan,sources=sources,pending=pending,
                  committed=committed,artifacts=artifacts,closure_path=closure_path,
                  source_rows_sha256=tuple(digest(stream_encoded(row)) for row in sources),
                  failure_path=failure_path,frame_map=[None]*(committed+len(pending)),epochs=set())
        nodes[identifier]=node;by_reference[key]=identifier
        if plan.get('metadata_mode') == MATERIALIZED_HTTP_MODE:
            for row in plan['materialized_http_origins']:
                import_origin(row,root,reference)
        for original in sources:
            if plan.get('metadata_mode') == MATERIALIZED_HTTP_MODE:
                continue  # Exact contained graph is independently verified below.
            if original.get('kind') in ('complete-stream','closed-prefix'):
                if set(original)!={'kind','path','sha256','batch'}:raise ValueError('Invalid offline Figure ancestor reference')
                load({k:original[k] for k in ('kind','path','sha256')})
            elif original.get('kind') not in ('http-archived','http-archived-light','http-archived-lean','retained-request'):
                raise ValueError('Unresolved offline Figure terminal authority')
        active.remove(key)
        return identifier
    def import_origin(row, container, container_reference):
        reference=row['source_reference'];key=tuple(reference[k] for k in ('kind','path','sha256'))
        if key in by_reference:return by_reference[key]
        if len(nodes)>=64:raise ValueError('Offline Figure origin bound exceeded')
        identifier=row['id']
        def local(ref):return materialized_local_file(container,ref)
        path=local(row['authority']);authority_raw=saved(path);authority=decode(authority_raw)
        if digest(authority_raw)!=reference['sha256'] or identifier!='figure-origin-'+reference['sha256']:
            raise ValueError('Imported Figure authority changed')
        plan=decode(saved(local(row['plan'])))
        materialized_observations(plan)
        committed=(plan['base_batches']+plan['observed_batches'] if reference['kind']=='complete-stream'
                   else decode(saved(local(row['failure'])))['committed_batches'])
        origin_root=container/identifier
        sources=journal(origin_root,plan,committed)
        artifacts=authority['artifacts'] if reference['kind']=='complete-stream' else decode(saved(local(row['failure'])))['artifacts']
        nodes[identifier]=dict(identifier=identifier,reference=dict(reference),path=path,root=origin_root,
            authority=authority,authority_raw=authority_raw,plan=plan,sources=sources,pending=row['pending'],
            committed=committed,artifacts=artifacts,
            source_rows_sha256=tuple(digest(stream_encoded(value)) for value in sources),
            imported_row_sha256=digest(encoded(row)),
            closure_path=local(row['closure']) if row['closure'] else None,
            failure_path=local(row['failure']) if row['failure'] else None,
            frame_map=[None]*len(row['frame_map']),epochs=set(),imported_row=row,
            container=container,container_reference=dict(container_reference))
        by_reference[key]=identifier
        return identifier
    phase('metadata_ancestry_load')
    manifest_raw=saved(source)
    original_manifest=decode(manifest_raw)
    if original_manifest.get('capture_format')!=FILES_STREAM_SCHEMA:
        raise ValueError('Offline materialization requires a complete normal stream')
    root_id=load({'kind':'complete-stream','path':str(source),'sha256':digest(manifest_raw)})
    top=nodes[root_id];root=top['root'];wiki,date=top['plan']['wiki'],top['plan']['date']
    # Bounds and all ancestry locators were checked before any full payload replay.
    phase('source_verify')
    complete=read_complete_capture(source,cache,include_document=False)
    if complete['manifest_sha256']!=digest(manifest_raw):raise ValueError('Offline complete Figure identity differs')
    observations.update(source_complete_verified=True,source_manifest_sha256=digest(manifest_raw))
    for node in nodes.values():
        if node['reference']['kind']=='closed-prefix' and 'imported_row' not in node:
            prefix=read_closed_prefix(node['path'],cache)
            if prefix['record']['schema']==SOURCE_PREFIX_SCHEMA:
                node['pending']=[terminal_pending(node['root'],ref,node['plan']['wiki'],lean=True) for ref in prefix['pending_batches']]
            else:
                node['pending']=([terminal_pending(node['root'],prefix['lookahead'],node['plan']['wiki'],lean=False)] if prefix['lookahead'] is not None else [])
            node['frame_map']=[None]*(node['committed']+len(node['pending']))
    if len(complete['offsets'])!=len(top['frame_map']):raise ValueError('Offline Figure source count differs')
    phase('frame_resolution')
    frames=[];planned=[]
    def scoped(identifier, value):
        result=copy.deepcopy(value)
        for name in ('batch','tiff_batch'):
            if name in result:result[name]={key:identifier+'/'+item for key,item in result[name].items()}
        for name in ('artifacts','tiff_artifacts'):
            if name in result:result[name]=[identifier+'/'+item for item in result[name]]
        return result
    def resolve(identifier,slot,number,batch,visiting):
        edge=(identifier,slot)
        if edge in visiting:raise ValueError('Cyclic offline Figure source echo')
        node=nodes[identifier]
        if type(slot) is not int or not 0<=slot<len(node['frame_map']):raise ValueError('Offline Figure source slot differs')
        if node['frame_map'][slot] not in (None,number):raise ValueError('Duplicate offline Figure source echo')
        node['frame_map'][slot]=number
        value=(node['sources'][slot] if slot < node['committed'] else
               node['pending'][slot-node['committed']])
        if node['plan'].get('metadata_mode') == MATERIALIZED_HTTP_MODE:
            other=node['plan']['materialized_root']
            result=resolve(other,slot,number,batch,visiting|{edge})
            if result!=value:raise ValueError('Offline materialized wrapper echo differs')
            return result
        if value['kind'] in ('complete-stream','closed-prefix'):
            ref={k:value[k] for k in ('kind','path','sha256')}
            other=by_reference[(ref['kind'],ref['path'],ref['sha256'])]
            if 'imported_row' in node:
                source_frame=dict(node['container_reference'],batch=node['imported_row']['frame_map'][slot])
                expected=complete_stream_batch(source_frame,cache)
            else:
                expected=(complete_stream_batch(value,cache) if value['kind']=='complete-stream' else closed_prefix_batch(value,cache))
            if expected!=batch:raise ValueError('Offline Figure ancestor batch changed')
            return resolve(other,value['batch'],number,batch,visiting|{edge})
        # Full verification above authenticated the immutable original leaf. A
        # fresh equality check keeps the admitted stream and source echo joined.
        if (slot < node['committed'] and not _verified_contained_http_leaf(
                node,slot,batch,cache,complete['namespace'],stamps)):
            replay_source(node['root'],value,batch,wiki,date,complete['namespace'],set(),cache,
                          profile_kind=node['plan'].get('figure_profile',FIGURE_PROFILE_V3),
                          allow_compatible_epochs=node['plan'].get('replay_contract') in (REPLAY_CONTRACT_V3, REPLAY_CONTRACT_V4, REPLAY_CONTRACT),
                          origin_plan=node['plan'])
        # Accepted pending bodies remain present in a physically closed failed
        # origin. read_closed_prefix authenticated them with the pending-specific
        # validator, and the caller above joined its exact returned batch to this
        # current frame. The archived/retired-body validator is inapplicable here.
        # check_prefix_cache below retains their original full identity fence.
        core=decode(batch['response'].encode())['query']['general']['git-hash']
        node['epochs'].add(core)
        return dict(value) if value['kind']=='retained-request' else scoped(identifier,value)
    raw_values=stream_values(root/ROLES['figure-sizing-raw'],RAW_STREAM_SCHEMA);next(raw_values)
    for number,batch in enumerate(raw_values):
        frame=resolve(root_id,number,number,batch,set());frames.append(frame)
        # Preserve the ordered HTTP-only plan while this exact raw frame is in
        # hand; retained observations do not contribute a request slot.
        if frame['kind'] in ('http-archived','http-archived-light','http-archived-lean'):
            planned.append(batch['requests'])
    if len(frames)!=len(top['frame_map']) or any(any(number is None for number in node['frame_map']) for node in nodes.values()):
        raise ValueError('Unresolved offline Figure origin frame')
    check()
    # This cache is owned by this operation. Source-to-frame resolution has
    # consumed its semantic documents; retain every offset and custody stamp
    # for the unchanged end guard without retaining million-record fact lists.
    for admitted in cache.values():
        if admitted is not None:admitted.pop('document',None)
    if link_current_payloads:
        source_identities.update((path,identity(path)) for path in complete['stamps'])
        if any(stamp(value)!=complete['stamps'][path] for path,value in source_identities.items()):
            raise ValueError('Linked Figure source changed after complete verification')
    expected_links={name:source_identities[root/name] for name in link_names} if link_current_payloads else {}
    if (len({value[:2] for value in expected_links.values()})!=len(expected_links) or
            any(stamp(value)!=complete['stamps'][root/name] for name,value in expected_links.items())):
        raise ValueError('Linked Figure payload identities are aliased or changed')
    phase('output_write')
    output.parent.mkdir(parents=True,exist_ok=True)
    if any(value[0]!=output.parent.stat().st_dev for value in expected_links.values()):
        raise ValueError('Linked Figure payloads require the same filesystem')
    lock=output.with_name('.'+output.name+'.capture.lock')
    fd=os.open(lock,os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW,0o600)
    try:
        info=os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink!=1 or info.st_uid!=os.getuid():
            raise ValueError('Unsafe offline Figure capture lock')
        fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
        output.mkdir(mode=0o700,exist_ok=False)
        owned_output=output_identity();observations['output_root']=owned_output
        def put(relative,path):
            observed_artifact_name(Path(relative).name)
            destination=output/relative;destination.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
            before=evidence.stamp(path)
            if before[2]>max_input_bytes:raise ValueError('Offline Figure copy bound exceeded')
            if destination.exists():
                if evidence.stamp(destination)[2]!=before[2] or digest(small(destination,max_input_bytes))!=digest(saved(path)):
                    raise ValueError('Offline Figure shared metadata collision')
                return {'path':relative,'bytes':before[2],'sha256':digest(small(destination,max_input_bytes))}
            if link_current_payloads and relative in link_names and Path(path)==root/relative:
                original=expected_links[relative]
                if identity(path)!=original:
                    raise ValueError('Figure payload changed before its owned hard link')
                os.link(path,destination,follow_symlinks=False)
                after=identity(path)
                row=dict(path=relative,before=dict(zip(fields,original)),after=dict(zip(fields,after)),
                         sha256_before=original_manifest['artifacts'][relative]['sha256'])
                observations['linked_members'].append(row)
                if (after[:7]!=original[:7] or after[7]!=original[7]+1 or after[8]<original[8] or
                        identity(destination)!=after):
                    raise ValueError('Figure hard link changed content, mode, identity or link count')
                accept_owned_link(original,after)
                linked[Path(path)]=(destination,after)
                return {'path':relative,'bytes':after[5],'sha256':row['sha256_before']}
            with Path(path).open('rb') as source_stream,destination.open('xb') as target:
                digestor=hashlib.sha256();size=0
                while raw:=source_stream.read(1024*1024):
                    target.write(raw);digestor.update(raw);size+=len(raw)
                target.flush();os.fsync(target.fileno())
            if evidence.stamp(path)!=before:raise ValueError('Offline Figure input changed during copy')
            return {'path':relative,'bytes':size,'sha256':digestor.hexdigest()}
        defaults=top['plan']['defaults']
        query_inputs=decode(saved(root/QUERY_INPUTS))
        base={*defaults,site_info.MANIFEST,site_info.COMPLETE,*ROLES.values(),INVENTORY,QUERY_INPUTS,PROVIDER,
              *(row['path'] for row in query_inputs)}
        for name in sorted(base):put(name,root/name)
        rows=[]
        for identifier,node in nodes.items():
            origin_root=node['root'];own=output/identifier;own.mkdir(mode=0o700)
            row=dict(id=identifier,source_reference=node['reference'],authority_kind=node['reference']['kind'],
                authority=put(identifier+'/authority.json',node['path']),complete=None,closure=None,failure=None,
                plan=put(identifier+'/'+PLAN,origin_root/PLAN),journal=put(identifier+'/'+FILE_REQUESTS,origin_root/FILE_REQUESTS),
                files={},pending=node['pending'],frame_map=node['frame_map'],epochs=sorted(node['epochs']))
            if node['reference']['kind']=='complete-stream':
                row['complete']=put(identifier+'/complete.json',
                    materialized_local_file(node['container'],node['imported_row']['complete'])
                    if 'imported_row' in node else origin_root/COMPLETE)
            else:
                row['closure']=put(identifier+'/closure.json',node['closure_path'])
                row['failure']=put(identifier+'/failure.json',node['failure_path'])
            required={QUERY_INPUTS,ROLES['figure-sizing-site']}
            required.update(item['path'] for item in node['plan']['query_inputs'])
            if node['plan'].get('metadata_mode') != MATERIALIZED_HTTP_MODE:
                for value in node['sources']+node['pending']:
                    for name in ('artifacts','tiff_artifacts'):required.update(value.get(name,[]))
            if node['reference']['kind']=='closed-prefix' and node['authority']['schema']==CLOSED_PREFIX_SCHEMA:
                closure=decode(saved(node['closure_path']))
                required.update(Path(closure[name]['path']).name for name in ('actual_request','actual_receipt','actual_response'))
            for name in sorted(required):
                observed_artifact_name(name)
                if 'imported_row' in node:
                    reference=node['imported_row']['files'][name]
                    row['files'][name]=put(reference['path'],materialized_local_file(node['container'],reference))
                else:
                    row['files'][name]=put(identifier+'/'+name,origin_root/name)
            rows.append(row)
        plan=copy.deepcopy(top['plan'])
        plan.update(metadata_mode=MATERIALIZED_HTTP_MODE,source=capture_source(),retained=[],
            closed_prefixes=[],complete_captures=[],metadata_light_titles=[],
            materialized_root=root_id,materialized_http_origins=rows)
        # This is an ordered source-echo inventory, not evidence of new HTTP.
        plan['planned_requests_sha256']=digest(encoded(planned))
        evidence.document(output/PLAN,plan)
        with (output/FILE_REQUESTS).open('xb') as stream:
            stream.write(stream_encoded({'schema':REQUEST_STREAM_SCHEMA,'batches':len(frames)}))
            for value in frames:stream.write(stream_encoded(value))
            stream.flush();os.fsync(stream.fileno())
        manifest=copy.deepcopy(original_manifest)
        manifest.update(producer());manifest['resumes']=[]
        manifest['artifacts']=payload(output)
        evidence.document(output/MANIFEST,manifest)
        # Authenticate the fresh output once. Publication adds only its exact
        # marker; retain all verified files and origin directories across it.
        phase('output_verify')
        members, directories = capture_member_paths(output,include_markers=True)
        output_stamps = {name:evidence.stamp(path) for name,path in members.items()}
        sql_paths = tuple(Path(row['path']) for row in complete['inventory']['sources'])
        external_authority = inventory_physical_authority(sql_paths)
        verified = verify(output,require_complete=False)
        after, after_directories = capture_member_paths(output,include_markers=True)
        if (verified != manifest or set(after) != set(members) or
                {name:evidence.stamp(path) for name,path in after.items()} != output_stamps or
                after_directories != directories):
            raise ValueError('Materialized Figure output changed during verification')
        if inventory_physical_authority(sql_paths) != external_authority:
            raise ValueError('Materialized Figure external authority changed during verification')
        check()
        phase('publish_final_custody')
        marker = {'schema':SCHEMA,'manifest_sha256':digest(small(output/MANIFEST))}
        evidence.document(output/COMPLETE,marker)
        ready, ready_directories = capture_member_paths(output,include_markers=True)
        if (set(ready) != set(members)|{COMPLETE} or
                any(evidence.stamp(ready[name]) != stamp for name,stamp in output_stamps.items()) or
                ready_directories[output][:3] != directories[output][:3] or
                {path:stamp for path,stamp in ready_directories.items() if path != output} !=
                    {path:stamp for path,stamp in directories.items() if path != output} or
                small(output/COMPLETE) != encoded(marker)):
            raise ValueError('Materialized Figure output changed during publication')
        if inventory_physical_authority(sql_paths) != external_authority:
            raise ValueError('Materialized Figure external authority changed during publication')
        check()
        if link_current_payloads and set(row['path'] for row in observations['linked_members'])!=link_names:
            raise ValueError('Figure materialization did not record its exact linked payloads')
        for row in observations['linked_members']:
            row['sha256_after']=verified['artifacts'][row['path']]['sha256']
        if link_current_payloads and not observe_link_custody(verified_artifacts=verified['artifacts']):
            raise ValueError('Materialized Figure link custody changed after verification')
        observations.update(complete=True,source_manifest_sha256=digest(manifest_raw),
                            source_complete_verified=True,source_content_mode_inode_preserved=True,
                            new_output_adoption_allowed=True,failed_link_recovery_verified=False)
        phase(None)
        return manifest
    except Exception:
        if link_current_payloads and owned_output is not None:
            if cleanup_failed_links:
                try:cleanup_owned_failed_links()
                except Exception as error:observations['cleanup_error']=str(error)
            try:observe_link_custody()
            except Exception as error:
                observations['failed_link_recovery_verified']=False
                observations.setdefault('custody_errors',[]).append(str(error))
        raise
    finally:
        fcntl.flock(fd,fcntl.LOCK_UN);os.close(fd)


def reproject_capture(source, output, *, target_contract=REPLAY_CONTRACT_V4,
                      target_profile=None, observations=None, repair_manifest_sha256=None):
    """Advance replay or explicitly select V5 without copying immutable members.

    A pinned repair_manifest_sha256 admits only a complete V5/replay.v4
    history for fresh raw derivation, never semantic trust in its old projection.
    Explicit replay.v6 advances v3/v4 with the same source profile; V5 profile
    advancement remains a separate replay.v4 operation.
    A materialized-origin capture may advance v3 to v4 without changing any
    original origin plan, receipt, frame map or semantic replay context.
    The original remains byte/mode/inode exact. Hard links intentionally change
    source nlink/ctime; record each transition, then fence the resulting identity
    through the unchanged full output verifier. No caller supplies trusted facts.
    An error preserves the incomplete output and its partial link observations.
    """
    if target_contract not in (REPLAY_CONTRACT_V4, REPLAY_CONTRACT):
        raise ValueError('Unsupported offline Figure reprojection contract')
    repair = repair_manifest_sha256 is not None
    if repair and (not isinstance(repair_manifest_sha256, str) or
            re.fullmatch('[0-9a-f]{64}', repair_manifest_sha256) is None or
            target_contract != REPLAY_CONTRACT_V4 or target_profile is not None):
        raise ValueError('Invalid pinned V5 replay.v4 repair selection')
    if (target_profile not in (None, FIGURE_PROFILE_V5) or
            target_profile is not None and target_contract != REPLAY_CONTRACT_V4):
        raise ValueError('Unsupported offline Figure target profile')
    if observations is None:
        observations = {}
    if type(observations) is not dict or observations:
        raise ValueError('Figure reprojection observations must be an empty output dictionary')
    observations.update(complete=False, linked_members=[], phases={})
    source, output = Path(source), Path(output)
    if (not source.is_absolute() or source.resolve() != source or source.is_symlink() or
            not output.is_absolute() or output.resolve() != output or os.path.lexists(output) or
            output.is_relative_to(source) or source.is_relative_to(output) or
            not output.parent.is_dir() or output.parent.stat().st_uid != os.geteuid()):
        raise ValueError('Figure reprojection requires an owned fresh independent output')

    fields = ('st_dev', 'st_ino', 'st_mode', 'st_uid', 'st_gid', 'st_size',
              'st_mtime_ns', 'st_nlink', 'st_ctime_ns')
    def identity(path):
        value = path.lstat()
        if not stat.S_ISREG(value.st_mode) or value.st_uid != os.geteuid():
            raise ValueError('Figure reprojection member is not an owned regular file')
        return tuple(getattr(value, name) for name in fields)
    def snapshot(root):
        members, directories = capture_member_paths(root, include_markers=True)
        if root.resolve() != root or any(p.stat().st_uid != os.geteuid() for p in directories):
            raise ValueError('Figure reprojection directory identity differs')
        return members, {name: identity(path) for name, path in members.items()}, directories
    members, original, source_directories = snapshot(source)
    if len({value[:2] for value in original.values()}) != len(original):
        raise ValueError('Figure reprojection source has aliased internal member identities')
    expected_source = dict(original)
    output_directories = {}
    def directory_identity(path):
        value = path.lstat()
        if (not stat.S_ISDIR(value.st_mode) or value.st_uid != os.geteuid() or
                path.resolve() != path):
            raise ValueError('Figure reprojection output directory identity differs')
        return (value.st_dev, value.st_ino, value.st_mode, value.st_uid, value.st_gid)
    def check_source():
        if any(directory_identity(path) != expected for path, expected in output_directories.items()):
            raise ValueError('Figure reprojection output directory changed')
        after, identities, directories = snapshot(source)
        if after != members or identities != expected_source or directories != source_directories:
            raise ValueError('Figure reprojection source changed outside its owned hard links')
    inventory_cache = {}
    started = time.monotonic()
    if repair:
        history_raw, manifest = _figure_capture_manifest(source)
        if digest(history_raw) != repair_manifest_sha256:
            raise ValueError('Figure repair manifest identity differs')
        # Authenticate every retained member as historical bytes. The complete
        # derived output below must pass unchanged semantic replay before COMPLETE.
        _authenticate_figure_capture_files(source, manifest, inventory_cache)
    else:
        manifest = verify(source, inventory_cache=inventory_cache)
    check_source()
    observations['phases']['source_verify_seconds'] = time.monotonic() - started
    manifest_raw = small(source / MANIFEST)
    if decode(manifest_raw) != manifest:
        raise ValueError('Figure reprojection source manifest changed')
    if (manifest.get('capture_format') != FILES_STREAM_SCHEMA or
            set(manifest.get('outputs', {})) != {*ROLES, 'file-metadata'}):
        raise ValueError('Figure reprojection requires a complete five-role stream capture')
    with (source / ROLES['figure-sizing']).open('rb') as stream:
        line = stream.readline(STREAM_HEADER_LIMIT + 1)
    if len(line) > STREAM_HEADER_LIMIT:
        raise ValueError('Figure reprojection source header exceeds its bound')
    header = stream_decode(line)
    validate_stream_header(header, FILES_STREAM_SCHEMA, original[ROLES['figure-sizing']][5])
    original_profile = (header['source_profile'] or {}).get('kind', FIGURE_PROFILE_V3)
    if repair:
        if original_profile != FIGURE_PROFILE_V5 or header.get('replay_contract') != REPLAY_CONTRACT_V4:
            raise ValueError('Pinned repair requires an existing V5 replay.v4 capture')
    elif target_contract == REPLAY_CONTRACT:
        if header.get('replay_contract') not in (REPLAY_CONTRACT_V3, REPLAY_CONTRACT_V4):
            raise ValueError('Explicit replay.v6 requires an existing replay.v3 or replay.v4 capture')
    elif target_profile is None:
        if header.get('replay_contract') not in (None, REPLAY_CONTRACT_V1, REPLAY_CONTRACT_V2, REPLAY_CONTRACT_V3):
            raise ValueError('Figure reprojection must advance a pre-v4 semantic contract')
    elif original_profile != FIGURE_PROFILE_V4 or header.get('replay_contract') != REPLAY_CONTRACT_V4:
        raise ValueError('Explicit V5 reprojection requires an existing V4 profile and replay.v4 capture')
    selected_profile = original_profile if target_profile is None else target_profile
    plan = inventory_document(source / PLAN)
    if type(plan) is not dict or plan.get('metadata_mode', 'full') not in ('full', MATERIALIZED_HTTP_MODE):
        raise ValueError('Figure reprojection requires a full or materialized-origin plan')
    if plan.get('metadata_mode') == MATERIALIZED_HTTP_MODE and (
            target_contract != REPLAY_CONTRACT_V4 or target_profile is not None or
            header.get('replay_contract') != REPLAY_CONTRACT_V3):
        raise ValueError('Materialized-origin reprojection requires replay.v3 to replay.v4 without a profile change')
    if repair and plan.get('metadata_mode', 'full') != 'full':
        raise ValueError('Pinned repair requires complete full capture authorities')
    new_plan = dict(plan, replay_contract=target_contract)
    if target_profile is not None:
        new_plan['figure_profile'] = target_profile
    namespace = small(source / (site_info.PREFIX + 'namespace-registry.tsv'))
    site = small(source / ROLES['figure-sizing-site'], MAX_RESPONSE)
    check_source()

    # Only these four files have new content or publication meaning. Never
    # hard-link then rewrite a source plan, projection, or completion marker.
    owned = {PLAN, ROLES['figure-sizing'], MANIFEST, COMPLETE}
    if not owned <= set(members):
        raise ValueError('Figure reprojection lacks its plan or complete source members')
    output.mkdir(mode=0o700)
    output_directories[output] = directory_identity(output)
    for directory in sorted(source_directories, key=str):
        if directory != source:
            destination_directory = output / directory.relative_to(source)
            destination_directory.mkdir(mode=0o700)
            output_directories[destination_directory] = directory_identity(destination_directory)
    link_started = time.monotonic()
    for name, path in sorted(members.items()):
        if name in owned:
            continue
        before = expected_source[name]
        if identity(path) != before:
            raise ValueError('Figure source changed before hard linking')
        destination = output / name
        os.link(path, destination, follow_symlinks=False)
        after = identity(path)
        observations['linked_members'].append(dict(path=name, before=dict(zip(fields, before)),
            after=dict(zip(fields, after)), sha256_before=manifest['artifacts'][name]['sha256']))
        if (after[:7] != before[:7] or after[7] != before[7] + 1 or after[8] < before[8] or
                identity(destination) != after):
            raise ValueError('Figure hard link changed source content, mode or identity')
        expected_source[name] = after
    check_source()
    observations['phases']['link_seconds'] = time.monotonic() - link_started
    evidence.document(output / PLAN, new_plan)
    generation_started = time.monotonic()
    records = _ReprojectionRecords(output / ROLES['figure-sizing-raw'], namespace,
        manifest['wiki'], manifest['date'], site, target_contract,
        profile_kind=selected_profile,
        allow_tiff_companion=True, allow_encoded=True, allow_compatible_epochs=True,
        allow_decimal_tiff_axes=True, allow_default_tiff_page=target_contract == REPLAY_CONTRACT)
    new_header = records.header()
    expected_header = dict(header)
    if target_profile is not None:
        general = decode(site)['query']['general']
        expected_header['source_profile'] = dict(figure_profile(general['git-hash'], target_profile),
            site_raw_sha256=digest(site))
    if ({key: value for key, value in new_header.items() if key not in ('generator_sha256', 'replay_contract')} !=
            {key: value for key, value in expected_header.items() if key not in ('generator_sha256', 'replay_contract')}):
        raise ValueError('Figure reprojection changed retained stream context')
    records.write(output / ROLES['figure-sizing'])
    inventory = verify_inventory(inventory_document(output / INVENTORY), namespace,
        manifest['wiki'], manifest['date'], inventory_cache=inventory_cache)
    query_titles = provider_query_titles(output, decode(small(output / QUERY_INPUTS)), namespace,
        manifest['wiki'], manifest['date'])
    coverage = records.coverage(inventory, query_titles)
    observations['phases']['derive_write_seconds'] = time.monotonic() - generation_started
    check_source()
    # Every linked member is rehashed by the unchanged verifier below against
    # its original authenticated digest. Only the two new payloads need new rows.
    artifacts = dict(manifest['artifacts'])
    for name in (PLAN, ROLES['figure-sizing']):
        value = evidence.fingerprint(output / name)
        artifacts[name] = dict(bytes=value['size'], sha256=value['sha256'])
    new_manifest = {**manifest, **producer(), 'coverage': coverage, 'artifacts': artifacts,
        'outputs': {role: artifacts[name]['sha256'] for role, name in output_roles(output).items()}}
    evidence.document(output / MANIFEST, new_manifest)
    before_members, before_output, before_directories = snapshot(output)
    if set(before_members) != set(members) - {COMPLETE} or os.path.lexists(output / COMPLETE):
        raise ValueError('Figure reprojection output membership changed before verification')
    verify_started = time.monotonic()
    verified = verify(output, require_complete=False, inventory_cache=inventory_cache,
                      _reprojection_records=records)
    after_members, after_output, after_directories = snapshot(output)
    if (verified != new_manifest or after_members != before_members or after_output != before_output or
            after_directories != before_directories or os.path.lexists(output / COMPLETE)):
        raise ValueError('Figure reprojection output changed during verification')
    check_source()
    observations['phases']['output_verify_seconds'] = time.monotonic() - verify_started
    marker = dict(schema=SCHEMA, manifest_sha256=digest(small(output / MANIFEST)))
    evidence.document(output / COMPLETE, marker)
    ready_members, ready, ready_directories = snapshot(output)
    if (set(ready_members) != set(members) or any(ready[name] != value for name, value in before_output.items()) or
            ready_directories[output][:3] != before_directories[output][:3] or
            {path: value for path, value in ready_directories.items() if path != output} !=
                {path: value for path, value in before_directories.items() if path != output} or
            small(output / COMPLETE) != encoded(marker)):
        raise ValueError('Figure reprojection output changed during publication')
    check_source()
    check_inventory_replay_cache(inventory_cache)
    for row in observations['linked_members']:
        row['sha256_after'] = verified['artifacts'][row['path']]['sha256']
    observations.update(complete=True, source_manifest_sha256=digest(manifest_raw),
        source_content_mode_inode_preserved=True, original_contract=header.get('replay_contract'),
        target_contract=target_contract, original_profile=original_profile, target_profile=selected_profile)
    if repair:
        observations['repair_manifest_sha256'] = repair_manifest_sha256
        observations['old_projection_semantically_trusted'] = False
    return new_manifest


def materialize_command(args):
    observations={}
    try:
        return materialize_complete_capture(args.source,args.output,max_batches=args.max_batches,
            max_input_bytes=args.max_input_bytes,link_current_payloads=args.link_current_payloads,
            cleanup_failed_links=getattr(args,'cleanup_failed_links',False),observations=observations,
            phase_progress=getattr(args,'phase_progress',False))
    finally:
        if args.link_current_payloads:
            # The caller retains this small stderr record on success or failure;
            # stdout keeps the existing manifest result shape.
            print(json.dumps(observations,sort_keys=True),file=sys.stderr,flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    check = commands.add_parser('verify')
    check.add_argument('output', type=Path)
    complete = commands.add_parser('complete-capture', help='fully verify an owned incomplete stream and insert only its completion marker')
    complete.add_argument('output', type=Path)
    for name in ('manifest-sha256', 'wiki', 'date'):
        complete.add_argument('--'+name, required=True)
    materialize = commands.add_parser('materialize-complete', help='offline self-contained materialization of an authenticated complete stream')
    materialize.add_argument('--source', type=Path, required=True)
    materialize.add_argument('--output', type=Path, required=True)
    materialize.add_argument('--max-batches', type=int, default=64)
    materialize.add_argument('--max-input-bytes', type=int, default=64*1024*1024)
    materialize.add_argument('--link-current-payloads', action='store_true',
        help='share the four unchanged payload inodes and emit exact custody observations on stderr')
    materialize.add_argument('--cleanup-failed-links',action='store_true',
        help='on failure remove only verified links created by this operation, retaining explicit cleanup evidence')
    materialize.add_argument('--phase-progress',action='store_true',
        help='flush fixed stage start/end diagnostics with wall and process CPU seconds on stderr')
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
    collect.add_argument('--max-inflight', type=int, choices=(1, 2), default=2)
    collect.add_argument('--metadata-mode', choices=('full', 'lean-tiff-v1'), default='full')
    collect.add_argument('--resume', type=Path, help='authenticated closed wall-stop prefix proof')
    collect.add_argument('--figure-profile', choices=(FIGURE_PROFILE_V3, FIGURE_PROFILE_V4, FIGURE_PROFILE_V5),
                         default=FIGURE_PROFILE_V3,
                         help='reviewed geometry profile; explicit selection preserves older projection policy')
    args = parser.parse_args()
    result = (stage(args) if args.command == 'stage' else capture_files(args) if args.command == 'capture-files' else
              materialize_command(args)
              if args.command == 'materialize-complete' else
              complete_capture(args.output, manifest_sha256=args.manifest_sha256, wiki=args.wiki, date=args.date)
              if args.command == 'complete-capture' else verify(args.output))
    print(encoded({key: result[key] for key in ('schema', 'wiki', 'date', 'coverage')}).decode(), end='')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError) as error:
        raise SystemExit(str(error)) from error
