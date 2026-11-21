"""Compare thin Mach-O payloads while accounting for code-signature growth.

The signature can grow __LINKEDIT into another VM page after a bundle is
signed. Normalize that segment to the unsigned length, only after checking
its file extent, page rounding, permissions and signature boundary. Every
other payload byte and load-command field participates in the comparison.
Signature validity is checked separately by codesign.
"""
from pathlib import Path
import argparse
import hashlib
import json
import struct


def normalize(data):
    if len(data) < 32 or struct.unpack_from('<I', data)[0] != 0xfeedfacf:
        raise ValueError('Expected a thin little-endian 64-bit Mach-O')
    cpu = struct.unpack_from('<I', data, 4)[0]
    pages = {0x0100000c: 16384, 0x01000007: 4096}
    if cpu not in pages:
        raise ValueError('Unsupported Mach-O CPU type')
    page = pages[cpu]
    count, command_bytes = struct.unpack_from('<II', data, 16)
    offset = 32
    linkedit = None
    signature = None
    segments = []
    for _ in range(count):
        if offset + 8 > 32 + command_bytes or offset + 8 > len(data):
            raise ValueError('Truncated Mach-O commands')
        command, size = struct.unpack_from('<II', data, offset)
        if size < 8 or offset + size > 32 + command_bytes or offset + size > len(data):
            raise ValueError('Invalid Mach-O command size')
        if command == 0x19:
            if size < 72:
                raise ValueError('Truncated segment command')
            name = data[offset + 8:offset + 24].rstrip(b'\0').decode('ascii')
            vmaddr, vmsize, fileoff, filesize = struct.unpack_from('<QQQQ', data, offset + 24)
            protection = struct.unpack_from('<I', data, offset + 60)[0]
            segment = dict(offset=offset, name=name, vmaddr=vmaddr, vmsize=vmsize,
                           fileoff=fileoff, filesize=filesize, protection=protection)
            segments.append(segment)
            if name == '__LINKEDIT':
                if linkedit is not None:
                    raise ValueError('Duplicate LINKEDIT segment')
                linkedit = segment
        if command == 0x1d:
            if size != 16 or signature is not None:
                raise ValueError('Invalid code-signature command')
            start, length = struct.unpack_from('<II', data, offset + 8)
            signature = dict(offset=offset, start=start, length=length)
        offset += size
    if offset != 32 + command_bytes or linkedit is None or signature is None:
        raise ValueError('Missing segment/signature or invalid command extent')
    start, length = signature['start'], signature['length']
    if length < 12 or start + length != len(data) or data[start:start + 4] != bytes.fromhex('fade0cc0'):
        raise ValueError('Invalid final embedded-signature extent')
    if (linkedit['protection'] & 4 or linkedit['fileoff'] > start
            or linkedit['fileoff'] + linkedit['filesize'] != len(data)
            or linkedit['vmsize'] != ((linkedit['filesize'] + page - 1) // page) * page):
        raise ValueError('LINKEDIT does not match a non-executable signature-sized final segment')
    if any(s is not linkedit and s['fileoff'] + s['filesize'] > linkedit['fileoff']
           for s in segments if s['filesize']):
        raise ValueError('Another segment overlaps LINKEDIT')
    unsigned_size = start - linkedit['fileoff']
    result = bytearray(data[:start])
    struct.pack_into('<I', result, signature['offset'] + 12, 0)
    struct.pack_into('<Q', result, linkedit['offset'] + 32, ((unsigned_size + page - 1) // page) * page)
    struct.pack_into('<Q', result, linkedit['offset'] + 48, unsigned_size)
    return bytes(result), dict(page_size=page, signature=signature, linkedit=linkedit, segments=segments)


def payload(path):
    return hashlib.sha256(normalize(Path(path).read_bytes())[0]).hexdigest()


def selftest(first, second):
    a, info = normalize(first)
    b, _ = normalize(second)
    results = []
    def check(value, name):
        if not value:
            raise AssertionError(name)
        results.append(name)
    check(a == b, 'actual signed payloads match')
    for name in ['__TEXT', '__DATA_CONST', '__LINKEDIT']:
        segment = next(s for s in info['segments'] if s['name'] == name)
        offset = segment['fileoff'] + (16384 if name == '__TEXT' else 0)
        changed = bytearray(first); changed[offset] ^= 1
        check(normalize(changed)[0] != a, 'detect payload change in ' + name)
    text = next(s for s in info['segments'] if s['name'] == '__TEXT')
    changed = bytearray(first)
    struct.pack_into('<Q', changed, text['offset'] + 32, text['vmsize'] + info['page_size'])
    check(normalize(changed)[0] != a, 'detect TEXT VM-layout change')
    changes = [
        (info['linkedit']['offset'] + 32, '<Q', info['linkedit']['vmsize'] + info['page_size'], 'reject unrelated LINKEDIT VM-layout change'),
        (info['signature']['offset'] + 8, '<I', info['signature']['start'] - 16, 'reject wrong signature boundary'),
        (info['signature']['start'], '>I', 0, 'reject wrong signature magic')]
    for offset, encoding, value, name in changes:
        changed = bytearray(first); struct.pack_into(encoding, changed, offset, value)
        try:
            normalize(changed)
        except ValueError:
            check(True, name)
        else:
            raise AssertionError(name)
    return results


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('binary', type=Path)
    parser.add_argument('packaged_binary', type=Path)
    parser.add_argument('--selftest', action='store_true')
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    first, second = args.binary.read_bytes(), args.packaged_binary.read_bytes()
    a, ai = normalize(first); b, bi = normalize(second)
    assert a == b, 'Executable payload differs from the application package'
    checks = selftest(first, second) if args.selftest else []
    record = dict(normalization_version=2, payloads_match=True, normalized_payload_sha256=hashlib.sha256(a).hexdigest(),
                  binary_sha256=hashlib.sha256(first).hexdigest(), packaged_sha256=hashlib.sha256(second).hexdigest(),
                  signature_bytes=[ai['signature']['length'], bi['signature']['length']],
                  LINKEDIT_VM_bytes=[ai['linkedit']['vmsize'], bi['linkedit']['vmsize']],
                  selftest_checks=checks, selftest_passed=len(checks))
    if args.report:
        args.report.write_text(json.dumps(record, indent=2) + '\n')
    print('PASS bundle payload matches (signature-neutral v2)' + (f'; {len(checks)} verifier checks' if checks else ''))
