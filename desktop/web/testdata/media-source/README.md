These ImageInfo API responses were retained for the source-wiki image regression.

- `sd-imageinfo.json`: `https://sd.wiktionary.org/w/api.php`, `File:antenna.jpg`; a local 150 by 107 JPEG.
- `commons-imageinfo.json`: `https://commons.wikimedia.org/w/api.php`, `File:antenna.jpg`; normalizes to the distinct `File:Antenna.jpg`.

The fixtures preserve the returned identity and URL metadata. Tests that change these responses are explicitly constructed controls, not additional provider captures. They make no network requests.
