# openssl

`openssl` is a toolkit for TLS and certificates. For debugging, two parts
matter most:

- **`openssl s_client`** opens a TLS connection to a server and shows the
  whole handshake: which certificates the server sent, whether they're valid,
  which TLS version and cipher were agreed.
- **`openssl x509`** reads a certificate and shows what's in it: names, issuer,
  expiry date, extensions.

kdbg has OpenSSL 3.

## When to use it in a cluster

- An Ingress serves the wrong certificate, or the controller's default "fake"
  certificate.
- Clients report `certificate has expired`, `unknown authority` or `hostname
  mismatch`.
- Admission or conversion webhooks fail with TLS errors.
- Checking that a TLS secret's certificate and key belong together.
- Checking mutual TLS, TLS versions or ALPN (for gRPC and HTTP/2).

## Privileges

None.

## Connecting to a server: s_client

```sh
openssl s_client -connect my-svc:443 -servername my-svc </dev/null
```

- `-connect host:port` is where to connect.
- `-servername` is the name sent for SNI. The server uses it to pick which
  certificate to send. OpenSSL sends the `-connect` host by default, but you
  need to set it when you connect by IP or through a different name than the
  one you want to test.
- `</dev/null` closes the connection after the handshake. Without it,
  `s_client` waits for you to type.

Useful options:

```sh
openssl s_client -connect my-svc:443 -brief </dev/null                 # Short summary
openssl s_client -connect my-svc:443 -showcerts </dev/null             # Print every certificate the server sent
openssl s_client -connect my-svc:443 -CAfile ca.crt </dev/null         # Verify against a specific CA
openssl s_client -connect my-svc:443 -verify_hostname my-svc </dev/null  # Also check the name matches
openssl s_client -connect my-svc:443 -verify_return_error </dev/null   # Fail if verification fails
openssl s_client -connect my-svc:443 -cert client.crt -key client.key </dev/null  # Present a client certificate
openssl s_client -connect my-svc:443 -alpn h2 </dev/null               # Offer HTTP/2 (gRPC needs this)
openssl s_client -connect my-svc:443 -tls1_2 </dev/null                # Only allow TLS 1.2 (or -tls1_3)
openssl s_client -connect db:5432 -starttls postgres </dev/null        # Protocols that upgrade to TLS
```

`-starttls` also accepts `smtp`, `imap`, `pop3`, `ftp`, `mysql`, `ldap`, `xmpp`
and a few others.

### Reading the output

The `-brief` form:

```text
CONNECTION ESTABLISHED
Protocol version: TLSv1.3
Ciphersuite: TLS_AES_256_GCM_SHA384
Peer certificate: CN=my-svc.my-namespace.svc
Hash used: SHA256
Signature type: ecdsa_secp256r1_sha256
Verification: OK
```

The full form shows the chain of certificates the server sent, with `s:`
(subject: who the certificate is for) and `i:` (issuer: who signed it):

```text
Certificate chain
 0 s:CN=app.example.com
   i:C=US, O=Let's Encrypt, CN=R11
 1 s:C=US, O=Let's Encrypt, CN=R11
   i:C=US, O=Internet Security Research Group, CN=ISRG Root X1
```

Each certificate's issuer should be the subject of the next one. The last one
should be signed by a CA the client trusts. Near the end you'll find the
verification result:

```text
Verify return code: 0 (ok)
```

Common codes:

| Code | Meaning |
| --- | --- |
| `0 (ok)` | The chain is valid and trusted. |
| `10 (certificate has expired)` | A certificate in the chain has expired. Check the dates. |
| `18 (self-signed certificate)` | The server's certificate signed itself, and you didn't say to trust it. |
| `19 (self-signed certificate in certificate chain)` | The chain ends at a CA you don't trust. Usually a private CA: pass it with `-CAfile`. |
| `20 (unable to get local issuer certificate)` | The issuer of a certificate is missing. Often the server doesn't send its intermediate certificate. |
| `21 (unable to verify the first certificate)` | Same idea: the server's certificate can't be linked to a trusted CA. |
| `62 (hostname mismatch)` | Only with `-verify_hostname`: the certificate isn't for that name. |

By default `s_client` connects even when verification fails, and doesn't check
the hostname at all. Use `-verify_return_error` and `-verify_hostname` to make
it behave like a strict client.

## Reading a certificate: x509

Get a server's certificate and show the parts that matter:

```sh
openssl s_client -connect my-svc:443 -servername my-svc </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates -ext subjectAltName
```

```text
subject=CN=my-svc.my-namespace.svc
issuer=CN=my-cluster-ca
notBefore=Sep 26 22:49:11 2026 GMT
notAfter=Dec 25 22:56:35 2026 GMT
X509v3 Subject Alternative Name:
    DNS:my-svc, DNS:my-svc.my-namespace, DNS:my-svc.my-namespace.svc
```

Clients check the name they connected to against the **Subject Alternative
Name** list. The subject's `CN` is ignored by modern clients, so a name only in
`CN` doesn't count.

Other ways to read certificates:

```sh
openssl x509 -in cert.pem -noout -text            # Everything
openssl x509 -in cert.pem -noout -enddate         # Expiry date only
openssl x509 -in cert.pem -noout -checkend 604800 # Exit status 1 if it expires within 7 days
openssl x509 -in cert.pem -noout -fingerprint -sha256
openssl crl2pkcs7 -nocrl -certfile chain.pem | openssl pkcs7 -print_certs -noout  # Every certificate in a bundle
```

## Recipes

### Which certificate does the Ingress serve for a host?

Connect to the Ingress controller and send the host name as SNI:

```sh
openssl s_client -connect ingress-nginx-controller.ingress-nginx:443 \
  -servername app.example.com </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates -ext subjectAltName
```

If the subject is something like `Kubernetes Ingress Controller Fake
Certificate`, the controller has no valid certificate for that host. Usually
the Ingress's `tls` section is missing that host, the secret name is wrong,
or the secret is in a different namespace than the Ingress.

### Check a webhook's certificate

The API server calls webhooks through a Service, at
`<service>.<namespace>.svc`, and checks the certificate against the
`caBundle` in the webhook configuration. Get the CA from your own machine:

```sh
kubectl get validatingwebhookconfiguration my-webhook \
  -o jsonpath='{.webhooks[0].clientConfig.caBundle}' | base64 -d > ca.crt
```

Copy it into kdbg (`kubectl cp`), then check the way the API server does:

```sh
openssl s_client -connect my-webhook.my-namespace.svc:443 \
  -CAfile ca.crt -verify_hostname my-webhook.my-namespace.svc \
  -verify_return_error -brief </dev/null
```

`Verification: OK` means the certificate and CA match. A failure tells you what
the API server sees: an expired certificate, a CA that doesn't match the
`caBundle`, or a certificate without `<service>.<namespace>.svc` in its names.

### Check the API server from a pod

Every pod gets the cluster's CA through its service account:

```sh
openssl s_client -connect kubernetes.default.svc:443 \
  -CAfile /var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
  -verify_return_error -brief </dev/null
```

### Does a key belong to a certificate?

A TLS secret with a mismatched key makes servers fail to start or fail every
handshake. Compare the public keys:

```sh
openssl x509 -in tls.crt -noout -pubkey | openssl sha256
openssl pkey -in tls.key -pubout | openssl sha256
```

The two hashes must be the same. To get the files from a secret, on your own
machine:

```sh
kubectl get secret my-tls -o jsonpath='{.data.tls\.crt}' | base64 -d > tls.crt
kubectl get secret my-tls -o jsonpath='{.data.tls\.key}' | base64 -d > tls.key
```

### Is the chain complete?

```sh
openssl s_client -connect app.example.com:443 -showcerts </dev/null 2>/dev/null | grep -E '^ +([0-9] )?[si]:'
```

If you only see certificate `0` and verification fails with code `20` or `21`,
the server doesn't send its intermediate certificate. Browsers often work
anyway, because they cache intermediates, but other clients fail. Fix it by
putting the full chain (server certificate first, then intermediates) in the
`tls.crt` of the secret.

### Check mutual TLS

```sh
openssl s_client -connect my-svc:443 -cert client.crt -key client.key -CAfile ca.crt -brief </dev/null
```

Without a client certificate, a server that requires one fails the handshake,
usually with an alert like `certificate required` or `handshake failure`.

### Check gRPC and HTTP/2

gRPC needs HTTP/2, which is agreed during the TLS handshake through ALPN:

```sh
openssl s_client -connect my-grpc:443 -alpn h2 </dev/null 2>/dev/null | grep ALPN
```

`ALPN protocol: h2` means the server (or the load balancer in front of it)
supports HTTP/2. `No ALPN negotiated` means it doesn't, and gRPC clients will
fail.

### Create a test certificate and server

A self-signed certificate valid for one day:

```sh
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -keyout server.key -out server.pem \
  -subj "/CN=test" -addext "subjectAltName=DNS:test,DNS:localhost"
```

A TLS test server using it, that shows what each client sends:

```sh
openssl s_server -accept 8443 -cert server.pem -key server.key -www
```

## Pitfalls

- **No `</dev/null`** and `s_client` waits for input forever.
- **Wrong or missing SNI** gives you the server's default certificate, which
  looks like a broken certificate. Set `-servername` whenever you connect by
  IP or through another name.
- **`s_client` doesn't fail on bad certificates** unless you pass
  `-verify_return_error`, and doesn't check the name unless you pass
  `-verify_hostname`.
- **Clock differences.** A certificate that's "not yet valid" or "expired" on
  one machine and fine on another points to a wrong clock. Compare `date`
  on both.
- **Load balancers terminate TLS.** If a cloud load balancer or an Ingress
  terminates TLS, connecting from outside shows *its* certificate, not your
  application's. Connect to the pod directly to see the application's.

## Related

- [socat](socat.md), for relaying TLS or adding TLS to a plain-text port
- [nc](nc.md), to check the port is reachable before debugging TLS
- [tcpdump](tcpdump.md), to see where in the handshake a connection fails

## Manuals

- [s_client](https://docs.openssl.org/3.5/man1/openssl-s_client/)
- [x509](https://docs.openssl.org/3.5/man1/openssl-x509/)
- [verify error codes](https://docs.openssl.org/3.5/man1/openssl-verification-options/)
