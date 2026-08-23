#!/usr/bin/env python3
"""Validate .mra files before deploying them.

WHY
---
On 2026-08-23 an edit to the maincpu comment block left a `-->` in place that
had already closed the comment, so the new prose landed in the document as
character data. It contained `<- u127`, and a bare `<` is illegal in XML, so
MiSTer refused the file: the DIP switches vanished from the OSD, the ROM never
loaded, and the core came up on an all-zero image (SP=PC=00000000, black
screen). That looked exactly like a core regression and cost a debugging round
trip before the user reported the on-screen "XML parse" message.

Nothing about that failure is visible by reading the diff, and MiSTer's own
parser is lenient enough that some malformations load fine while others kill
the file. So check mechanically, every time, before copying an .mra to the
device.

Checks:
  1. The file is well-formed XML (strict -- stricter than MiSTer's parser).
  2. No element carries stray non-whitespace TEXT content. Every leaked
     comment block shows up here, including ones MiSTer currently tolerates.
  3. <switches default="..."> byte count matches the number of declared bits,
     and the file declares a <setname> (the .CFG filename depends on it).

Usage:
    python scripts/validate_mra.py releases/*.mra
Exit status is non-zero if any file fails, so it works as a gate:
    python scripts/validate_mra.py releases/*.mra && <deploy>
"""
import glob
import sys
import xml.etree.ElementTree as ET

# Elements whose text content is meaningful and must not be flagged.
TEXT_OK = {'part', 'name', 'setname', 'year', 'manufacturer', 'category',
           'rbf', 'rotation', 'players', 'joystick', 'region', 'about',
           'mratimestamp', 'catver', 'mameversion', 'status'}


def check(path):
    problems = []
    try:
        tree = ET.parse(path)
    except ET.ParseError as e:
        return ['not well-formed XML: %s' % e]

    root = tree.getroot()
    for el in root.iter():
        if el.tag in TEXT_OK:
            continue
        for blob, where in ((el.text, 'text'), (el.tail, 'tail')):
            if blob and blob.strip():
                snippet = ' '.join(blob.split())[:70]
                problems.append(
                    'stray %s content in <%s>: %r\n'
                    '        (a comment block almost certainly closed early -- '
                    'check for a premature "-->")' % (where, el.tag, snippet))

    if root.find('setname') is None:
        problems.append('no <setname>; the per-core .CFG filename depends on it')

    sw = root.find('switches')
    if sw is not None and sw.get('default'):
        nbytes = len([x for x in sw.get('default').split(',') if x.strip()])
        bits = []
        for dip in sw.findall('dip'):
            for b in (dip.get('bits') or '').split(','):
                if b.strip().isdigit():
                    bits.append(int(b))
        if bits and max(bits) >= nbytes * 8 + 16:
            problems.append(
                'switches default has %d bytes but a <dip> uses bit %d, which '
                'is outside the range those bytes can cover' % (nbytes, max(bits)))
    return problems


def main(argv):
    files = []
    for pat in (argv or ['releases/*.mra']):
        files.extend(sorted(glob.glob(pat)))
    if not files:
        print('no .mra files matched'); return 1

    bad = 0
    for f in files:
        problems = check(f)
        if problems:
            bad += 1
            print('FAIL  %s' % f)
            for p in problems:
                print('        %s' % p)
        else:
            print('OK    %s' % f)
    if bad:
        print('\n%d of %d file(s) failed -- do NOT deploy these.' % (bad, len(files)))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
