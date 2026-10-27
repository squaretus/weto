# Bug: the geo probe times out for minutes on a healthy VPN

## Symptom

On macOS the popup sat on «Выход не подтверждён» with both services failing
«таймаут запроса (ожидание ответа)», `сеть: есть`, and the targets paused — while the VPN (Happ,
`utun6`, address `198.18.0.1`) was working. It came and went «randomly»; a manual check did not help,
and the series ended on its own after a few minutes or after a network change.

## What the check log said

`checks.json` (50 entries) split cleanly into two kinds:

```
13:46:23 schedule failed out=utun6/198.18.0.1 7503 | ipinfo: таймаут (ожидание ответа) [dns 0 connect 0 tls 0]
                                                     geojs-self: таймаут (ожидание ответа) [dns 0 connect 0 tls 0]
… the same every 10 s for minutes …
09:05:53 networkChanged answered out=en0/…  ipinfo ok [dns 2 connect 826 tls 761]
```

Every failure on `utun6` had DNS, connect and TLS all `0`. `MetricsCollector.phases` writes `0` for
connect only when `isReusedConnection` is true — so each failed request went out over a connection
taken from the session's pool, sent its bytes and never got an answer. Every success after a network
change had real connect and TLS times: a new connection.

## Root cause

`URLSessionHTTPFetcher` built one `URLSession` for the whole life of the app, so its connection pool
did too. `198.18.0.0/15` is a fake-IP tunnel (sing-box/Clash style): when the client restarts or
switches nodes it drops live TCP connections silently, without RST. The verdict fingerprint
(`utun6/198.18.0.1`) does not change, so nothing invalidated the pool, and every probe was handed
the same dead connection until the system gave up on it. The first «не доказано» pauses the targets,
so each such series cost the user a pause.

Linux is not affected: `ureq::get` in ureq 2.x builds a fresh `Agent` per call
(`AgentBuilder::new().build()`), so there is no pool between requests — checked in the ureq 2.12.1
source. A test pins that property.

## Fix

`URLSessionHTTPFetcher` creates a session per request and invalidates it with the response
(`invalidateAndCancel`), so a probe never inherits a connection. Cost: DNS + TCP + TLS per request —
a probe already asks different hosts, so there was nothing to reuse within one.

## Tests

- `HTTPFetcherPhasesTests.test_a_silent_pooled_connection_is_not_reused_by_the_next_request`:
  a server answers the first request with keep-alive, keeps that connection open and silent, and
  answers only on a second connection. Red with the shared session (timeout `-1001`, the same as in
  the user's log), green with the fix. It replaced the test that asserted reuse as expected behaviour.
- `weto-sys/tests/geo_probe.rs::a_silent_pooled_connection_is_not_reused_by_the_next_request`:
  the same scenario through `HttpGeoProbe` — green on Linux before and after; it guards against a
  future shared `Agent`.
