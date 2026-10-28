#!/usr/bin/env python3
# 用法：scripts/verify-device-signature.py ../../testvectors/webauthn/device/signer-safetx.json（需要 pip 包 cryptography）
#       testdata/device-signature-*.json 同样适用
# 独立于 Apple 的复验：按 docs/webauthn-signature.md 重建消息，用 OpenSSL（cryptography）验签。
import base64, hashlib, json, sys
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature
from cryptography.hazmat.primitives import hashes

v = json.load(open(sys.argv[1]))
x, y = int(v["x"], 16), int(v["y"], 16)
challenge = bytes.fromhex(v["challenge"][2:])
sig = bytes.fromhex(v["proxySignature"][2:])
word = lambda i: int.from_bytes(sig[32*i:32*i+32], "big")
auth_off, fields_off, r, s = word(0), word(1), word(2), word(3)
def dyn(off):
    n = int.from_bytes(sig[off:off+32], "big"); return sig[off+32:off+32+n]
auth, fields = dyn(auth_off), dyn(fields_off).decode()
n = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551
cdj = '{"type":"webauthn.get","challenge":"%s",%s}' % (base64.urlsafe_b64encode(challenge).rstrip(b"=").decode(), fields)
msg = auth + hashlib.sha256(cdj.encode()).digest()
pub = ec.EllipticCurvePublicNumbers(x, y, ec.SECP256R1()).public_key()
pub.verify(encode_dss_signature(r, s), msg, ec.ECDSA(hashes.SHA256()))  # 失败会抛异常
print("authenticatorData", auth.hex())
rp_id = v.get("rpId", "unipass.xyz")
print("  rpIdHash == sha256(%r):" % rp_id, auth[:32] == hashlib.sha256(rp_id.encode()).digest(), " flags:", hex(auth[32]), " signCount:", auth[33:].hex())
print("clientDataFields", fields)
print("clientDataJSON  ", cdj)
print("low-s:", s <= n // 2)
print("OpenSSL verify: OK")
