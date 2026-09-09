"""Password hashing, session tokens, and encryption of stored Ark secrets.

Password hashing uses stdlib scrypt so there's no native-build dependency.
Ark tokens are encrypted at rest with a Fernet key derived from
VISTA_SECRET_KEY — a Vista database on its own is not enough to reach
anyone's Ark server.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import os
import secrets
from datetime import datetime, timedelta, timezone

import jwt
from cryptography.fernet import Fernet, InvalidToken
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

from . import config

# scrypt parameters. n=2**15 is ~100ms per hash on commodity hardware, which
# is the point.
_SCRYPT_N = 2**15
_SCRYPT_R = 8
_SCRYPT_P = 1
_SALT_BYTES = 16

# scrypt needs 128 * N * r bytes (~33 MB at these parameters), which is over
# OpenSSL's 32 MB default ceiling — without an explicit maxmem every hash
# fails with "digital envelope routines::memory limit exceeded".
_SCRYPT_MAXMEM = 128 * _SCRYPT_N * _SCRYPT_R * 2


def hash_password(password: str) -> str:
    salt = os.urandom(_SALT_BYTES)
    digest = hashlib.scrypt(
        password.encode("utf-8"),
        salt=salt,
        n=_SCRYPT_N,
        r=_SCRYPT_R,
        p=_SCRYPT_P,
        maxmem=_SCRYPT_MAXMEM,
    )
    return f"scrypt${_SCRYPT_N}${_SCRYPT_R}${_SCRYPT_P}${salt.hex()}${digest.hex()}"


def verify_password(password: str, stored: str) -> bool:
    try:
        scheme, n, r, p, salt_hex, digest_hex = stored.split("$")
        if scheme != "scrypt":
            return False
        computed = hashlib.scrypt(
            password.encode("utf-8"),
            salt=bytes.fromhex(salt_hex),
            n=int(n),
            r=int(r),
            p=int(p),
            # Sized from the stored parameters so hashes written with
            # different settings still verify.
            maxmem=128 * int(n) * int(r) * 2,
        )
    except (ValueError, TypeError):
        return False
    return hmac.compare_digest(computed.hex(), digest_hex)


def _fernet() -> Fernet:
    """Derive the at-rest encryption key from the app secret.

    HKDF with a distinct `info` label keeps this key independent of the JWT
    signing use of the same secret.
    """
    kdf = HKDF(
        algorithm=hashes.SHA256(),
        length=32,
        salt=None,
        info=b"vista.ark-token.v1",
    )
    key = kdf.derive(config.require_secret_key().encode("utf-8"))
    return Fernet(base64.urlsafe_b64encode(key))


def encrypt_secret(plaintext: str) -> str:
    return _fernet().encrypt(plaintext.encode("utf-8")).decode("ascii")


def decrypt_secret(ciphertext: str) -> str:
    try:
        return _fernet().decrypt(ciphertext.encode("ascii")).decode("utf-8")
    except InvalidToken as exc:
        raise ValueError(
            "stored Ark token could not be decrypted — VISTA_SECRET_KEY has "
            "likely changed since it was saved"
        ) from exc


def issue_session(user_id: int, email: str) -> tuple[str, datetime]:
    expires = datetime.now(timezone.utc) + timedelta(hours=config.SESSION_TTL_HOURS)
    token = jwt.encode(
        {"sub": str(user_id), "email": email, "exp": expires, "jti": secrets.token_hex(8)},
        config.require_secret_key(),
        algorithm="HS256",
    )
    return token, expires


def read_session(token: str) -> dict | None:
    try:
        return jwt.decode(token, config.require_secret_key(), algorithms=["HS256"])
    except jwt.PyJWTError:
        return None
