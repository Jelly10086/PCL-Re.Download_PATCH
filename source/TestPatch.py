"""Exercise the shipped Windows PowerShell entry point on isolated copies."""
import argparse
import hashlib
import json
import shutil
import struct
import subprocess
import uuid
import zipfile
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(path, *args, ok=True):
    result = subprocess.run(
        ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
         str(ROOT / "LauncherPatch.ps1"), "-TargetPath", str(path), *map(str, args)],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90,
    )
    if (result.returncode == 0) != ok:
        raise AssertionError(result.stdout.decode("utf-8", errors="replace"))
    return result.stdout.decode("utf-8", errors="replace")


def cycle(source, directory):
    directory.mkdir()
    target = directory / ("launcher test ! 中文" + source.suffix)
    shutil.copy2(source, target)
    before = digest(target)
    run(target, "-CheckOnly")
    assert digest(target) == before and list(directory.iterdir()) == [target]
    run(target)
    after = digest(target)
    assert before != after, "Restriction was not patched"
    backup = Path(str(target) + ".download-original.bak")
    record = Path(str(target) + ".download-patch.json")
    assert digest(backup) == before
    manifest = json.loads(record.read_text(encoding="utf-8-sig"))
    assert manifest["OriginalHash"] == before and manifest["PatchedHash"] == after
    metadata = record.read_bytes()
    run(target)
    assert digest(target) == after and record.read_bytes() == metadata
    run(target, "-Restore", "-CheckOnly")
    assert digest(target) == after
    patched = target.read_bytes()
    target.write_bytes(patched + b"changed")
    changed = digest(target)
    run(target, "-Restore", ok=False)
    assert digest(target) == changed
    target.write_bytes(patched)
    original = backup.read_bytes()
    backup.write_bytes(original + b"broken")
    run(target, "-Restore", ok=False)
    assert digest(target) == after
    backup.write_bytes(original)
    run(target, "-Restore")
    assert digest(target) == before
    run(target, "-Restore")
    assert digest(target) == before
    assert not list(directory.glob("*.tmp")) and not list(directory.glob("*.lock"))
    print("PASS", directory.name, flush=True)


def compressed_bundle(source, destination):
    data = bytearray(source.read_bytes())
    signature = bytes.fromhex("8b1202b96a612038727b930214d7a03213f5b9e6efae3318ee3b2dce24b36aae")
    marker = data.index(signature)
    offset = struct.unpack_from("<q", data, marker - 8)[0]
    major, minor, count = struct.unpack_from("<IIi", data, offset)
    assert major == 6 and minor == 0
    position = offset + 12

    def string():
        nonlocal position
        length = shift = 0
        while True:
            byte = data[position]
            position += 1
            length |= (byte & 127) << shift
            shift += 7
            if byte < 128:
                break
        result = data[position:position + length].decode()
        position += length
        return result

    string()
    position += 40
    for _ in range(count):
        record = position
        start, length, compressed = struct.unpack_from("<qqq", data, position)
        position += 24
        kind = data[position]
        position += 1
        name = string()
        if kind == 1 and name == "Plain Craft Launcher 2.dll":
            contents = data[start:start + (compressed or length)]
            if compressed:
                contents = zlib.decompress(contents, -15)
            compressor = zlib.compressobj(wbits=-15)
            packed = compressor.compress(contents) + compressor.flush()
            struct.pack_into("<qqq", data, record, len(data), len(contents), len(packed))
            data.extend(packed)
            destination.write_bytes(data)
            return
    raise AssertionError("Main assembly not found")


def upgrade(source, directory):
    directory.mkdir()
    target = directory / 'legacy launcher.exe'
    for suffix in ('', '.download-original.bak', '.download-patch.json'):
        shutil.copy2(Path(str(source) + suffix), Path(str(target) + suffix))
    record = Path(str(target) + '.download-patch.json')
    backup = Path(str(target) + '.download-original.bak')
    before = digest(target)
    original = digest(backup)
    metadata = record.read_bytes()
    run(target, '-CheckOnly')
    assert digest(target) == before and record.read_bytes() == metadata
    run(target)
    repaired = digest(target)
    assert repaired != before and digest(backup) == original
    assert json.loads(record.read_text(encoding='utf-8-sig'))['OriginalHash'] == original
    metadata = record.read_bytes()
    run(target)
    assert digest(target) == repaired and record.read_bytes() == metadata
    run(target, '-Restore')
    assert digest(target) == original
    print('PASS legacy patch upgrade and original backup preserved', flush=True)


def main():
    parser = argparse.ArgumentParser()
    for name in ("pcl", "ce", "hmcl", "unrestricted-hmcl", "pcl-version", "mismatched-pcl", "legacy-pcl"):
        parser.add_argument("--" + name, type=Path, required=name in ("pcl", "ce", "hmcl"))
    parser.add_argument("--work-dir", type=Path, required=True)
    args = parser.parse_args()
    if args.legacy_pcl:
        upgrade(args.legacy_pcl, args.work_dir / ('upgrade-' + uuid.uuid4().hex))
    work = args.work_dir.resolve() / ("patch-tests-" + uuid.uuid4().hex[:8])
    work.mkdir()
    for name in ("pcl", "ce", "hmcl", "pcl_version"):
        sample = getattr(args, name)
        if sample:
            cycle(sample.resolve(), work / name)
    jar = work / "HMCL.jar"
    data = args.hmcl.read_bytes()
    end = data.rfind(b"PK\x05\x06")
    size, offset = struct.unpack_from("<II", data, end + 12)
    jar.write_bytes(data[end - size - offset:])
    with zipfile.ZipFile(jar) as archive:
        assert archive.testzip() is None
    cycle(jar, work / "hmcl-jar")
    compressed = work / "CE-Compressed.exe"
    compressed_bundle(args.ce, compressed)
    cycle(compressed, work / "ce-compressed")
    unknown = work / "unknown.exe"
    unknown.write_bytes(b"MZ" + b"not a supported launcher" * 10)
    before = digest(unknown)
    run(unknown, ok=False)
    assert digest(unknown) == before and not Path(str(unknown) + ".download-original.bak").exists()
    output = work / "occupied.exe"
    output.write_bytes(b"keep this file")
    before = digest(output)
    run(args.pcl.resolve(), "-OutputPath", output, ok=False)
    assert digest(output) == before
    if args.mismatched_pcl:
        mismatch = work / "mismatch.exe"
        shutil.copy2(args.mismatched_pcl, mismatch)
        before = digest(mismatch)
        run(mismatch, ok=False)
        assert digest(mismatch) == before and not Path(str(mismatch) + ".download-original.bak").exists()
    if args.unrestricted_hmcl:
        old = work / "old-HMCL.exe"
        shutil.copy2(args.unrestricted_hmcl, old)
        before = digest(old)
        run(old)
        assert digest(old) == before and not Path(str(old) + ".download-original.bak").exists()
    print("PASS unknown / occupied output / unrestricted launcher", flush=True)
    print("Test artifacts:", work, flush=True)


if __name__ == "__main__":
    main()
