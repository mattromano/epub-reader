"""Generate small valid EPUB 2 / EPUB 3 test books (plus a long one) into a target dir."""
import random, struct, sys, zipfile, zlib
from pathlib import Path

out = Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)
WORDS = ("the quiet river ran past old stone houses while a reader turned another page "
         "and thought about margins notes light evening tea ships letters wind").split()


def solid_png(width, height, rgb):
    """A valid solid-colour RGB PNG, built with zlib (no image libraries needed)."""
    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    row = b"\x00" + bytes(rgb) * width
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(row * height, 9))
            + chunk(b"IEND", b""))

def paragraphs(rng, n_words):
    left, out_p = n_words, []
    while left > 0:
        k = min(left, rng.randint(40, 120))
        out_p.append(" ".join(rng.choice(WORDS) for _ in range(k)).capitalize() + ".")
        left -= k
    return out_p

def chapter_xhtml(title, paras, v3):
    head = ('<?xml version="1.0" encoding="UTF-8"?>\n'
            + ('<!DOCTYPE html>\n<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">'
               if v3 else
               '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">\n'
               '<html xmlns="http://www.w3.org/1999/xhtml">'))
    body = "".join(f"<p>{p}</p>\n" for p in paras)
    return f"{head}<head><title>{title}</title></head><body><h1>{title}</h1>\n{body}</body></html>"

def build(name, title, author, v3, chapters, words_per_chapter, seed):
    rng = random.Random(seed)
    path = out / name
    with zipfile.ZipFile(path, "w") as z:
        z.writestr(zipfile.ZipInfo("mimetype"), "application/epub+zip", compress_type=zipfile.ZIP_STORED)
        z.writestr("META-INF/container.xml",
                   '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
                   '<rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>',
                   compress_type=zipfile.ZIP_DEFLATED)
        items, spine, navpoints, navlis = [], [], [], []
        for i in range(1, chapters + 1):
            fn = f"ch{i:03d}.xhtml"
            z.writestr(f"OEBPS/{fn}", chapter_xhtml(f"Chapter {i}", paragraphs(rng, words_per_chapter), v3),
                       compress_type=zipfile.ZIP_DEFLATED)
            items.append(f'<item id="c{i}" href="{fn}" media-type="application/xhtml+xml"/>')
            spine.append(f'<itemref idref="c{i}"/>')
            navpoints.append(f'<navPoint id="n{i}" playOrder="{i}"><navLabel><text>Chapter {i}</text></navLabel><content src="{fn}"/></navPoint>')
            navlis.append(f'<li><a href="{fn}">Chapter {i}</a></li>')
        colour = [(52, 101, 164), (164, 52, 77), (60, 140, 90)][seed % 3]
        z.writestr("OEBPS/cover.png", solid_png(600, 900, colour), compress_type=zipfile.ZIP_STORED)
        uid = f"urn:uuid:00000000-0000-4000-8000-{seed:012d}"
        z.writestr("OEBPS/toc.ncx",
                   f'<?xml version="1.0" encoding="UTF-8"?><ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">'
                   f'<head><meta name="dtb:uid" content="{uid}"/></head><docTitle><text>{title}</text></docTitle>'
                   f'<navMap>{"".join(navpoints)}</navMap></ncx>', compress_type=zipfile.ZIP_DEFLATED)
        if v3:
            z.writestr("OEBPS/nav.xhtml",
                       '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE html><html xmlns="http://www.w3.org/1999/xhtml" '
                       'xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head><body>'
                       f'<nav epub:type="toc"><ol>{"".join(navlis)}</ol></nav></body></html>',
                       compress_type=zipfile.ZIP_DEFLATED)
            manifest_extra = ('<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>'
                              '<item id="cover" href="cover.png" media-type="image/png" properties="cover-image"/>')
            meta_extra = '<meta property="dcterms:modified">2026-11-22T00:00:00Z</meta>'
        else:
            manifest_extra = '<item id="cover" href="cover.png" media-type="image/png"/>'
            meta_extra = '<meta name="cover" content="cover"/>'
        z.writestr("OEBPS/content.opf",
                   f'<?xml version="1.0" encoding="UTF-8"?><package xmlns="http://www.idpf.org/2007/opf" '
                   f'version="{"3.0" if v3 else "2.0"}" unique-identifier="uid">'
                   f'<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="uid">{uid}</dc:identifier>'
                   f'<dc:title>{title}</dc:title><dc:creator>{author}</dc:creator><dc:language>en</dc:language>{meta_extra}</metadata>'
                   f'<manifest><item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>{manifest_extra}{"".join(items)}</manifest>'
                   f'<spine toc="ncx">{"".join(spine)}</spine></package>', compress_type=zipfile.ZIP_DEFLATED)
    print(f"{name}: {chapters * words_per_chapter} words, {path.stat().st_size} bytes")

build("margins-test-epub3.epub", "Test Novel (EPUB 3)", "Ada Fixture", True, 12, 3000, 1)
build("margins-test-epub2.epub", "Test Novel (EPUB 2)", "Bertram Fixture", False, 8, 2500, 2)
build("margins-test-long.epub", "Very Long Test Book", "Cora Fixture", True, 120, 2600, 3)
(out / "margins-test-broken.epub").write_bytes(b"this is not a zip file")
print("margins-test-broken.epub: not a zip")
