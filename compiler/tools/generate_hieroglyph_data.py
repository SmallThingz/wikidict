"""Generate attributed factual hieroglyph mapping data from the captured literal maps."""
import argparse, hashlib, json, re
from pathlib import Path
def generate(source, output):
    raw=Path(source).read_bytes()
    assert hashlib.sha256(raw).hexdigest()=='407969a6e14aa3ab1ba133bf679556687b46ca89dbb5767dc24d0863ba6269fb'
    text=raw.decode()
    def pairs(field):
        part=text.split('data.'+field+' = {',1)[1].split('\n}',1)[0]
        rows=re.findall(r'\["([^"\\]+)"\]\s*=\s*"([^"\\\n]*)"',part)
        assert len({key for key,_ in rows})==len(rows)
        return dict(rows)
    raw_signs=pairs('hiero_map')
    canonical={k:v for k,v in raw_signs.items() if re.fullmatch(r'[A-Z][A-Za-z]*[0-9]+[A-Za-z]*',k) and len(v)==1 and 0x13000<=ord(v)<=0x1342f}
    candidates={}
    for field in ('mdc_phonogram_map','mdc_normalization_map'):
        for key,value in pairs(field).items():
            if key in canonical or not re.fullmatch(r'[A-Za-z][A-Za-z0-9]*',key) or value not in canonical:continue
            candidates.setdefault(key,set()).add(canonical[value])
    aliases={key:next(iter(values)) for key,values in candidates.items() if len(values)==1}
    excluded=sorted(key for key,values in candidates.items() if len(values)!=1)
    entries={**canonical,**aliases}
    lines=['// Generated factual mapping data; see hieroglyph_unicode.NOTICE.',
           '// Source: en.wiktionary.org Module:egy-hieroglyphs/data revision 90914315.',
           '// Mapping attribution retained under CC BY-SA 4.0; no Lua runtime dependency.',
           'pub const Entry = struct { name: []const u8, glyph: []const u8 };',
           'pub const entries = [_]Entry{']
    for key in sorted(entries):
        lines.append('    .{ .name = '+json.dumps(key)+', .glyph = '+json.dumps(entries[key],ensure_ascii=False)+' },')
    lines.append('};')
    Path(output).write_text('\n'.join(lines)+'\n')
    return dict(canonical=len(canonical),aliases=len(aliases),excluded_conflicts=excluded,entries=len(entries),sha256=hashlib.sha256(Path(output).read_bytes()).hexdigest())
if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--source',required=True);parser.add_argument('--output',required=True);options=parser.parse_args()
    print(json.dumps(generate(options.source,options.output)))
