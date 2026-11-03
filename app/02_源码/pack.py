import os, sys, zipfile, shutil

root = os.path.dirname(os.path.abspath(__file__))
out = os.path.join(root, "out")
base = os.path.join(out, "base.apk")
dex = os.path.join(out, "dex", "classes.dex")
dst = os.path.join(out, "unsigned.apk")

if not os.path.exists(base):
    print("missing base.apk"); sys.exit(1)
if not os.path.exists(dex):
    print("missing classes.dex"); sys.exit(1)

with zipfile.ZipFile(base) as zin, zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as zout:
    for item in zin.infolist():
        data = zin.read(item.filename)
        # resources.arsc must be stored uncompressed and 4-byte aligned on Android 11+
        # keep aapt2 per-entry policy: raw wav must stay STORED for SoundPool.openRawResourceFd
        method = zipfile.ZIP_STORED if item.filename == "resources.arsc" else item.compress_type
        zout.writestr(item.filename, data, compress_type=method)
    zout.write(dex, "classes.dex", compress_type=zipfile.ZIP_DEFLATED)

print("packed", dst, os.path.getsize(dst), "bytes")


