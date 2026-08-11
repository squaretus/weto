//! Гео-проба проверяется на локальном HTTP-сервере с записанными ответами.
//!
//! Сервер поднимается прямо здесь, на обычном TcpListener: три ответа в трёх
//! форматах — весь протокол, который нужен пробе, и тащить ради него
//! веб-фреймворк не за что.

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use weto_core::geo::{GeoFailure, GeoOutcome, SourceOutcome};
use weto_sys::geo_probe::{GeoEndpoints, GeoProbing, HttpGeoProbe, NetworkPathReporting};

/// Ответ, который сервер отдаёт на путь.
#[derive(Clone)]
struct Canned {
    status: u16,
    body: String,
}

struct FakeGeoService {
    port: u16,
    routes: Arc<Mutex<HashMap<String, Canned>>>,
    requests: Arc<AtomicUsize>,
}

impl FakeGeoService {
    fn start() -> FakeGeoService {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let routes: Arc<Mutex<HashMap<String, Canned>>> = Arc::new(Mutex::new(HashMap::new()));
        let requests = Arc::new(AtomicUsize::new(0));

        let served = routes.clone();
        let counted = requests.clone();
        std::thread::spawn(move || {
            for stream in listener.incoming().flatten() {
                counted.fetch_add(1, Ordering::SeqCst);
                serve(stream, &served);
            }
        });

        FakeGeoService {
            port,
            routes,
            requests,
        }
    }

    fn answers(self, path: &str, status: u16, body: &str) -> FakeGeoService {
        self.routes.lock().unwrap().insert(
            path.to_string(),
            Canned {
                status,
                body: body.to_string(),
            },
        );
        self
    }

    fn endpoints(&self) -> GeoEndpoints {
        let base = format!("http://127.0.0.1:{}", self.port);
        GeoEndpoints {
            ipinfo: format!("{base}/ipinfo"),
            freeipapi: format!("{base}/freeipapi/{{ip}}"),
            geojs: format!("{base}/geojs/{{ip}}"),
            geojs_self: format!("{base}/geojs-self"),
        }
    }

    fn request_count(&self) -> usize {
        self.requests.load(Ordering::SeqCst)
    }
}

fn serve(mut stream: TcpStream, routes: &Arc<Mutex<HashMap<String, Canned>>>) {
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    let mut request_line = String::new();
    if reader.read_line(&mut request_line).is_err() {
        return;
    }
    // Заголовки дочитываются до пустой строки, иначе клиент увидит обрыв.
    let mut header = String::new();
    while reader
        .read_line(&mut header)
        .map(|n| n > 0)
        .unwrap_or(false)
    {
        if header.trim().is_empty() {
            break;
        }
        header.clear();
    }

    let path = request_line
        .split_whitespace()
        .nth(1)
        .unwrap_or("/")
        .to_string();
    let canned = routes.lock().unwrap().get(&path).cloned();

    let response = match canned {
        Some(canned) => format!(
            "HTTP/1.1 {} OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
            canned.status,
            canned.body.len(),
            canned.body
        ),
        None => {
            "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".to_string()
        }
    };
    let _ = stream.write_all(response.as_bytes());
}

struct HasPath(bool);

impl NetworkPathReporting for HasPath {
    fn has_path(&self) -> bool {
        self.0
    }
}

fn probe_of(service: &FakeGeoService, has_path: bool) -> HttpGeoProbe {
    HttpGeoProbe::new(service.endpoints(), Box::new(HasPath(has_path)))
        .with_timeout(std::time::Duration::from_secs(2))
}

#[test]
fn both_services_answering_gives_a_verdict() {
    let service = FakeGeoService::start()
        .answers(
            "/ipinfo",
            200,
            r#"{"ip":"203.0.113.7","country_code":"NL"}"#,
        )
        .answers("/freeipapi/203.0.113.7", 200, r#"{"countryCode":"NL"}"#);

    let report = probe_of(&service, true).probe(Some("token"));

    let GeoOutcome::Resolved(reading) = report.outcome() else {
        panic!("оба сервиса ответили — вердикт обязан быть разрешённым");
    };
    assert_eq!(reading.ip, "203.0.113.7");
    assert_eq!(reading.primary_country, "NL");
    assert_eq!(reading.confirmed_country.as_deref(), Some("NL"));
    assert!(report.is_fully_answered());
}

#[test]
fn confirmation_falls_back_to_the_second_service() {
    let service = FakeGeoService::start()
        .answers(
            "/ipinfo",
            200,
            r#"{"ip":"203.0.113.7","country_code":"NL"}"#,
        )
        .answers("/freeipapi/203.0.113.7", 429, "")
        .answers("/geojs/203.0.113.7", 200, r#"{"country":"NL"}"#);

    let report = probe_of(&service, true).probe(Some("token"));

    assert!(matches!(report.outcome(), GeoOutcome::Resolved(_)));
    assert_eq!(
        report.confirm_source.map(|s| s.name()),
        Some("geojs"),
        "источник обязан называться тем, кто реально ответил"
    );
}

/// Когда молчат оба подтверждающих, в отчёт идёт причина первого,
/// а не общая «недоступность»: чинить пользователь будет именно его.
#[test]
fn when_both_confirmations_stay_silent_the_first_reason_survives() {
    let service = FakeGeoService::start()
        .answers(
            "/ipinfo",
            200,
            r#"{"ip":"203.0.113.7","country_code":"NL"}"#,
        )
        .answers("/freeipapi/203.0.113.7", 429, "")
        .answers("/geojs/203.0.113.7", 500, "");

    let report = probe_of(&service, true).probe(Some("token"));

    assert_eq!(
        report.confirmation,
        SourceOutcome::Failed(GeoFailure::RateLimited(429))
    );
}

/// Без токена страна показывается, но вердикта нет: `outcome` требует ipinfo
/// и остаётся fail-closed.
#[test]
fn without_a_token_the_reference_country_is_shown_but_never_decides() {
    let service = FakeGeoService::start().answers(
        "/geojs-self",
        200,
        r#"{"country":"NL","ip":"203.0.113.7"}"#,
    );

    let report = probe_of(&service, true).probe(None);

    assert_eq!(report.reference_country(), Some("NL"));
    assert_eq!(report.ip.as_deref(), Some("203.0.113.7"));
    assert!(matches!(report.outcome(), GeoOutcome::Unavailable(_)));
}

#[test]
fn rejected_token_is_named_by_its_status() {
    let service = FakeGeoService::start().answers("/ipinfo", 401, "");

    let report = probe_of(&service, true).probe(Some("stale-token"));

    assert_eq!(
        report.ipinfo,
        SourceOutcome::Failed(GeoFailure::Unauthorized(401))
    );
    assert_eq!(
        report.confirmation,
        SourceOutcome::NotRequested,
        "молчащий ipinfo не должен тратить лимит подтверждающего"
    );
}

/// Токен уезжает в HTTP-заголовок, где допустим только печатный ASCII.
/// Вставленный из буфера мусор обязан получить понятное объяснение,
/// а не «Bad Header» от библиотеки.
#[test]
fn a_token_with_forbidden_characters_is_explained_not_forwarded() {
    let service =
        FakeGeoService::start().answers("/ipinfo", 200, r#"{"ip":"1.2.3.4","country_code":"NL"}"#);

    let report = probe_of(&service, true).probe(Some("токен с кириллицей"));

    let SourceOutcome::Failed(failure) = &report.ipinfo else {
        panic!("такой токен не может быть принят");
    };
    assert!(
        failure.display_text().contains("недопустимые символы"),
        "показано: {}",
        failure.display_text()
    );
    assert_eq!(
        service.request_count(),
        0,
        "в сеть с таким токеном не ходим"
    );
}

/// Адрес из ответа подставляется в URL подтверждающих сервисов.
/// Непроверенная строка оттуда — прямой путь к запросу не туда.
#[test]
fn malformed_address_from_ipinfo_stops_the_probe() {
    let service = FakeGeoService::start().answers(
        "/ipinfo",
        200,
        r#"{"ip":"203.0.113.7/../../admin","country_code":"NL"}"#,
    );

    let report = probe_of(&service, true).probe(Some("token"));

    assert!(matches!(report.ipinfo, SourceOutcome::Failed(_)));
    assert_eq!(report.confirmation, SourceOutcome::NotRequested);
    assert_eq!(service.request_count(), 1, "второго запроса быть не должно");
}

#[test]
fn unparseable_answer_is_not_mistaken_for_an_answer() {
    let service = FakeGeoService::start().answers("/ipinfo", 200, "это не json");

    let report = probe_of(&service, true).probe(Some("token"));

    assert!(matches!(report.ipinfo, SourceOutcome::Failed(_)));
    assert!(matches!(report.outcome(), GeoOutcome::Unavailable(_)));
}

#[test]
fn absence_of_a_network_path_is_recorded_in_the_report() {
    let service =
        FakeGeoService::start().answers("/ipinfo", 200, r#"{"ip":"1.2.3.4","country_code":"NL"}"#);

    let report = probe_of(&service, false).probe(Some("token"));

    assert!(
        !report.has_network_path,
        "попап обязан отличать «сервис молчит» от «сети нет»"
    );
}
