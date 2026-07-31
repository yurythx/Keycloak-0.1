#!/usr/bin/env python3
"""Cria uma conta no Vaultwarden com senha mestra pre-definida,
replicando a criptografia client-side do proprio Bitwarden (o servidor
nunca ve a senha em texto claro nem os dados descriptografados - PBKDF2
pra derivar a master key, HKDF pra "esticar" ela, AES-256-CBC+HMAC-SHA256
pra proteger a chave simetrica do usuario e o par de chaves RSA).

So funciona com SIGNUPS_ALLOWED=true no momento da execucao (o proprio
Vaultwarden recusa registrar se estiver desligado - ver
docs/06-vaultwarden.md#autorregistro). Uso tipico:

    1. Editar docker-compose.yml: SIGNUPS_ALLOWED "false" -> "true"
    2. docker compose up -d --force-recreate vaultwarden
    3. python3 scripts/vaultwarden_create_user.py http://127.0.0.1:8081 \\
           suporte@rondonopolis.mt.gov.br "SenhaForte123!" "Suporte TI"
    4. Editar docker-compose.yml de volta: "true" -> "false"
    5. docker compose up -d --force-recreate vaultwarden

Requer o pacote "cryptography" (pip install cryptography).

Uso: python3 vaultwarden_create_user.py <base_url> <email> <senha> [nome]
"""
import base64
import hashlib
import hmac
import json
import os
import sys
import urllib.error
import urllib.request

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.padding import PKCS7

KDF_ITERATIONS = 600_000


def pbkdf2(secret: bytes, salt: bytes, iterations: int, length: int = 32) -> bytes:
    return hashlib.pbkdf2_hmac("sha256", secret, salt, iterations, dklen=length)


def hkdf_expand(prk: bytes, info: bytes, length: int = 32) -> bytes:
    # HKDF-Expand-SHA256, um bloco (length <= 32 cabe num unico T(1)).
    return hmac.new(prk, info + bytes([1]), hashlib.sha256).digest()[:length]


def aes_cbc_hmac_encrypt(data: bytes, enc_key: bytes, mac_key: bytes) -> str:
    """Formato "EncryptionType 2" do Bitwarden: AesCbc256_HmacSha256_B64."""
    iv = os.urandom(16)
    padder = PKCS7(128).padder()
    padded = padder.update(data) + padder.finalize()
    encryptor = Cipher(algorithms.AES(enc_key), modes.CBC(iv)).encryptor()
    ct = encryptor.update(padded) + encryptor.finalize()
    mac = hmac.new(mac_key, iv + ct, hashlib.sha256).digest()
    b64 = lambda b: base64.b64encode(b).decode()
    return f"2.{b64(iv)}|{b64(ct)}|{b64(mac)}"


def make_master_key(password: str, email: str) -> bytes:
    return pbkdf2(password.encode(), email.strip().lower().encode(), KDF_ITERATIONS, 32)


def hash_master_password(password: str, master_key: bytes) -> str:
    return base64.b64encode(pbkdf2(master_key, password.encode(), 1, 32)).decode()


def stretch_key(master_key: bytes) -> bytes:
    return hkdf_expand(master_key, b"enc", 32) + hkdf_expand(master_key, b"mac", 32)


def http_post_json(url: str, payload: dict) -> dict | str:
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read().decode())


def get_verification_token(base_url: str, email: str, name: str) -> str:
    # Sem SMTP configurado (mail_enabled=false), o Vaultwarden devolve o
    # token JWT direto na resposta em vez de mandar e-mail - ver
    # src/api/identity.rs::register_verification_email no vaultwarden.
    url = base_url.rstrip("/") + "/identity/accounts/register/send-verification-email"
    return http_post_json(url, {"email": email, "name": name})


def create_user(base_url: str, email: str, password: str, name: str) -> None:
    email_verification_token = get_verification_token(base_url, email, name)

    master_key = make_master_key(password, email)
    master_password_hash = hash_master_password(password, master_key)
    stretched_master_key = stretch_key(master_key)

    user_key = os.urandom(64)  # 32 bytes chave AES + 32 bytes chave HMAC
    protected_user_key = aes_cbc_hmac_encrypt(
        user_key, stretched_master_key[:32], stretched_master_key[32:]
    )

    rsa_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    public_key_der = rsa_key.public_key().public_bytes(
        encoding=serialization.Encoding.DER,
        format=serialization.PublicFormat.SubjectPublicKeyInfo,
    )
    private_key_der = rsa_key.private_bytes(
        encoding=serialization.Encoding.DER,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )
    protected_private_key = aes_cbc_hmac_encrypt(private_key_der, user_key[:32], user_key[32:])

    payload = {
        "name": name,
        "email": email,
        "emailVerificationToken": email_verification_token,
        "masterPasswordHash": master_password_hash,
        "masterPasswordHint": None,
        "key": protected_user_key,
        "keys": {
            "publicKey": base64.b64encode(public_key_der).decode(),
            "encryptedPrivateKey": protected_private_key,
        },
        "kdf": 0,  # PBKDF2-SHA256 (mesmo padrao do restante desta stack)
        "kdfIterations": KDF_ITERATIONS,
        "kdfMemory": None,
        "kdfParallelism": None,
    }

    url = base_url.rstrip("/") + "/identity/accounts/register/finish"
    result = http_post_json(url, payload)
    print(f"Conta criada com sucesso: {email}")
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    if len(sys.argv) < 4:
        print(__doc__)
        sys.exit(1)
    _base_url, _email, _password = sys.argv[1], sys.argv[2], sys.argv[3]
    _name = sys.argv[4] if len(sys.argv) > 4 else _email.split("@")[0]
    try:
        create_user(_base_url, _email, _password, _name)
    except urllib.error.HTTPError as exc:
        print(f"ERRO: HTTP {exc.code}")
        print(exc.read().decode())
        print(
            "\nSe a mensagem falar de 'Registration not allowed', o "
            "SIGNUPS_ALLOWED ainda esta 'false' - siga os passos do "
            "cabecalho deste arquivo pra ligar temporariamente antes de "
            "rodar de novo."
        )
        sys.exit(1)
