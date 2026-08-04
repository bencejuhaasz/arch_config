#!/bin/bash
mkdir -p /etc/tpm2-pcr-signing
openssl genrsa -out /etc/tpm2-pcr-signing/private.pem 2048
openssl rsa -in /etc/tpm2-pcr-signing/private.pem -pubout -out /etc/tpm2-pcr-signing/public.pem
chmod 600 /etc/tpm2-pcr-signing/private.pem
