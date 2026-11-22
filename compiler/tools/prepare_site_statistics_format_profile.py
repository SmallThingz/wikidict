"""Pure request/profile proposal; transport and complete-marker lifecycle not armed."""
import json
import re
import unicodedata

KEYS = ('pages', 'articles', 'images', 'edits', 'users', 'activeusers', 'admins')
BEGIN = 'BEGIN-WIKIDICT-PINNED-STATISTICS-FORMAT-V1'
END = 'END-WIKIDICT-PINNED-STATISTICS-FORMAT-V1'
MAX_VALUE = (1 << 53) - 1

def configuration(site, site_sha):
    if not isinstance(site, dict) or site.get('schema') != 'wikidict.site-info.v2':
        raise ValueError('Pinned site-info v2 required')
    if not isinstance(site_sha, str) or re.fullmatch('[0-9a-f]{64}', site_sha) is None:
        raise ValueError('Exact site-info SHA required')
    wiki, date, lang = (site.get(k) for k in ('wiki', 'date', 'content_language'))
    general = site.get('query', {}).get('general', {})
    stats = site.get('query', {}).get('statistics', {})
    if (not isinstance(wiki, str) or re.fullmatch('[a-z0-9_-]+wiktionary', wiki) is None
            or not isinstance(date, str) or re.fullmatch('[0-9]{8}', date) is None
            or not isinstance(lang, str) or re.fullmatch('[a-z0-9-]{2,64}', lang) is None
            or general.get('wikiid') != wiki or general.get('lang') != lang
            or not isinstance(stats, dict)):
        raise ValueError('Pinned site identity differs')
    namespace_sha = site.get('namespace_registry_sha256')
    if not isinstance(namespace_sha, str) or re.fullmatch('[0-9a-f]{64}', namespace_sha) is None:
        raise ValueError('Pinned namespace identity required')
    raw = {}
    for key in KEYS:
        value = stats.get(key)
        if type(value) is not int or not 0 <= value <= MAX_VALUE:
            raise ValueError('Missing/invalid pinned counter: ' + key)
        raw[key] = str(value)
    return dict(wiki=wiki, date=date, content_language=lang,
                namespace_registry_sha256=namespace_sha, site_info_sha256=site_sha, raw=raw)

def query(config):
    lines = [BEGIN]
    for key in KEYS:
        raw = config['raw'][key]
        if not isinstance(raw, str) or re.fullmatch('0|[1-9][0-9]*', raw) is None or int(raw) > MAX_VALUE:
            raise ValueError('Noncanonical literal counter')
        lines.extend((key + '={{formatnum:' + raw + '}}',
                      key + '-RAW={{formatnum:' + raw + '|R}}'))
    lines.append(END)
    return dict(action='expandtemplates', format='json', formatversion='2',
                prop='wikitext', title='API', uselang='en', maxlag='5', text='\n'.join(lines))

def profile(config, response):
    if (not isinstance(response, dict) or any(k in response for k in ('error', 'errors', 'warnings', 'continue'))
            or not isinstance(response.get('expandtemplates'), dict)):
        raise ValueError('Incomplete API response')
    text = response['expandtemplates'].get('wikitext')
    if not isinstance(text, str) or '\r' in text:
        raise ValueError('Missing formatted response')
    lines = text.split('\n')
    if len(lines) != 16 or lines[0] != BEGIN or lines[-1] != END:
        raise ValueError('Formatting frame differs')
    values = []
    for index, key in enumerate(KEYS):
        line, raw_line = lines[1 + 2 * index:3 + 2 * index]
        prefix = key + '='
        if not line.startswith(prefix) or raw_line != key + '-RAW=' + config['raw'][key]:
            raise ValueError('Formatting key/raw control differs')
        value = line[len(prefix):]
        if (not value or len(value.encode('utf-8')) > 256
                or any(unicodedata.category(c) in ('Cc', 'Cs') for c in value)
                or any(c in value for c in '<>{}|[]')):
            raise ValueError('Unsupported formatted value')
        values.append(dict(key=key, raw=config['raw'][key], formatted=value))
    return dict(schema='wikidict.site-statistics-format.v1',
                **{k: config[k] for k in ('wiki', 'date', 'content_language',
                   'namespace_registry_sha256', 'site_info_sha256')}, values=values)

def encoded(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':')) + '\n').encode('utf-8')
