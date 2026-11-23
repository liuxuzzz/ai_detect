# Local proxy TLS test fixtures

`proxy_test_ca.pem` is a test-only root certificate. `proxy_test_cert.pem` and
`proxy_test_key.pem` identify the synthetic host `relay.proxy.test` during local
HTTP CONNECT and SOCKS5 tests. They are never loaded by the application.

The root is trusted explicitly inside the tests. Production certificate
verification remains enabled. Renew the test server certificate before it
expires, keeping the DNS subject alternative name and `serverAuth` usage.
