"""Reject admin credentials before building and inspect the resulting APK."""
import argparse
import base64
import json
import os
import re
import zipfile

def public_client_key(value):
    if value.startswith('sb_publishable_'):
        return len(value) > len('sb_publishable_')
    try:
        payload=value.split('.')[1]
        claims=json.loads(base64.urlsafe_b64decode(payload+'='*(-len(payload)%4)))
        return claims.get('role')=='anon'
    except (IndexError,ValueError,TypeError):
        return False

if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--apk')
    args=parser.parse_args()
    if not public_client_key(os.environ.get('SUPABASE_PUBLISHABLE_KEY','')):
        raise SystemExit('FAIL: Mobile build must use a publishable/anon key, never a server credential')
    if args.apk:
        found_public=False
        with zipfile.ZipFile(args.apk) as apk:
            for info in apk.infolist():
                if info.is_dir() or info.filename.endswith(('.png','.jpg','.webp','.ttf','.otf')):
                    continue
                data=apk.read(info)
                # Search actual key-shaped values, not the validator's prefix literal.
                if re.search(rb'sb_secret_[A-Za-z0-9_-]{24,}',data):
                    raise SystemExit('FAIL: packaged server credential detected (value redacted)')
                key=os.environ['SUPABASE_PUBLISHABLE_KEY']
                found_public=found_public or key.encode() in data or key.encode('utf-16le') in data
        if not found_public:
            raise SystemExit('FAIL: configured public key not found in APK')
    print('PASS: mobile credential boundary verified; no secret value printed')
