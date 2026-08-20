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
use weto_sys::geo_probe::{
    GeoEndpoints, GeoProbing, HttpGeoProbe, NetworkPathReporting, CONFIRMATION_HARD_TTL,
    CONFIRMATION_SOFT_TTL,
};

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
    /// Обращения по путям: кэш подтверждения проверяется именно счётом запросов.
    hits: Arc<Mutex<HashMap<String, usize>>>,
}

impl FakeGeoService {
    fn start() -> FakeGeoService {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let routes: Arc<Mutex<HashMap<String, Canned>>> = Arc::new(Mutex::new(HashMap::new()));
        let requests = Arc::new(AtomicUsize::new(0));

        let served = routes.clone();
        let counted = requests.clone();
        let hits: Arc<Mutex<HashMap<String, usize>>> = Arc::new(Mutex::new(HashMap::new()));
        let tallied = hits.clone();
        std::thread::spawn(move || {
            for stream in listener.incoming().flatten() {
                counted.fetch_add(1, Ordering::SeqCst);
                serve(stream, &served, &tallied);
            }
        });

        FakeGeoService {
            port,
            routes,
            requests,
            hits,
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

    /// Ответ по ходу теста: сервис отвечает иначе, чем в начале.
    fn answers_now(&self, path: &str, status: u16, body: &str) {
        self.routes.lock().unwrap().insert(
            path.to_string(),
            Canned {
                status,
                body: body.to_string(),
            },
        );
    }

    fn hits(&self, path: &str) -> usize {
        self.hits.lock().unwrap().get(path).copied().unwrap_or(0)
    }
}

fn serve(
    mut stream: TcpStream,
    routes: &Arc<Mutex<HashMap<String, Canned>>>,
    hits: &Arc<Mutex<HashMap<String, usize>>>,
) {
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
    *hits.lock().unwrap().entry(path.clone()).or_insert(0) += 1;
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

/// Время — граница системы: потолки кэша иначе пришлось бы ждать по-настоящему.
#[derive(Clone)]
struct MovableClock(Arc<Mutex<std::time::Instant>>);

impl MovableClock {
    fn start() -> MovableClock {
        MovableClock(Arc::new(Mutex::new(std::time::Instant::now())))
    }

    fn advance(&self, by: std::time::Duration) {
        let mut now = self.0.lock().unwrap();
        *now += by;
    }
}

fn probe_with_clock(service: &FakeGeoService, clock: &MovableClock) -> HttpGeoProbe {
    let handle = clock.0.clone();
    probe_of(service, true).with_clock(Box::new(move || *handle.lock().unwrap()))
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
        service.hits("/freeipapi/{ip}"),
        0,
        "лимит подтверждающего сервиса не тратится: подтверждать нечего, адреса нет"
    );
    assert!(
        matches!(report.outcome(), GeoOutcome::Unavailable(_)),
        "отвергнутый токен оставляет вердикт fail-closed"
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
    assert!(
        matches!(report.outcome(), GeoOutcome::Unavailable(_)),
        "мусорный адрес не может стать вердиктом"
    );
    assert_eq!(
        service.hits("/freeipapi/203.0.113.7/../../admin"),
        0,
        "мусорная строка не уезжает в URL чужого сервиса"
    );
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

/// Отказ ipinfo не оставляет нас без адреса: он и есть то, чем потом доказывают,
/// что перепроверять страну не нужно.
#[test]
fn when_ipinfo_refuses_the_probe_asks_the_reference_source_for_its_own_address() {
    let service = FakeGeoService::start().answers("/ipinfo", 429, "").answers(
        "/geojs-self",
        200,
        r#"{"country":"NL","ip":"203.0.113.7"}"#,
    );

    let report = probe_of(&service, true).probe(Some("token"));

    assert_eq!(
        report.ipinfo,
        SourceOutcome::Failed(GeoFailure::RateLimited(429))
    );
    assert_eq!(report.ip.as_deref(), Some("203.0.113.7"));
    assert_eq!(report.reference_country(), Some("NL"));
    assert!(
        matches!(report.outcome(), GeoOutcome::Unavailable(_)),
        "без ответа ipinfo вердикт обязан остаться fail-closed"
    );
}

/// Подтверждение отвечает «в какой стране вот этот адрес». У неизменного адреса
/// ответ не меняется каждые пять секунд, а квота сервиса считается на адрес выхода
/// VPN и делится с соседями по узлу.
#[test]
fn confirmation_is_not_asked_again_for_the_same_address() {
    let service = FakeGeoService::start()
        .answers(
            "/ipinfo",
            200,
            r#"{"ip":"203.0.113.7","country_code":"NL"}"#,
        )
        .answers("/freeipapi/203.0.113.7", 200, r#"{"countryCode":"NL"}"#);
    let probe = probe_of(&service, true);

    for _ in 0..5 {
        assert!(matches!(
            probe.probe(Some("token")).outcome(),
            GeoOutcome::Resolved(_)
        ));
    }

    assert_eq!(
        service.hits("/freeipapi/203.0.113.7"),
        1,
        "адрес тот же — подтверждать нечего"
    );
    assert_eq!(
        service.hits("/ipinfo"),
        5,
        "ipinfo и есть детектор смены страны"
    );
}

#[test]
fn confirmation_is_refreshed_after_the_soft_ceiling() {
    let service = FakeGeoService::start()
        .answers(
            "/ipinfo",
            200,
            r#"{"ip":"203.0.113.7","country_code":"NL"}"#,
        )
        .answers("/freeipapi/203.0.113.7", 200, r#"{"countryCode":"NL"}"#);
    let clock = MovableClock::start();
    let probe = probe_with_clock(&service, &clock);

    let _ = probe.probe(Some("token"));
    clock.advance(CONFIRMATION_SOFT_TTL + std::time::Duration::from_secs(1));
    service.answers_now("/freeipapi/203.0.113.7", 200, r#"{"countryCode":"RU"}"#);

    let GeoOutcome::Resolved(reading) = probe.probe(Some("token")).outcome() else {
        panic!("ожидался разрешённый вердикт");
    };
    assert_eq!(reading.confirmed_country.as_deref(), Some("RU"));
}

/// Неудачное обновление в пределах жёсткого потолка ничего не меняет: годный ответ
/// про этот адрес у нас есть, и чужой 429 не повод завершать цели.
#[test]
fn failed_refresh_keeps_the_previous_confirmation() {
    let service = FakeGeoService::start()
        .answers(
            "/ipinfo",
            200,
            r#"{"ip":"203.0.113.7","country_code":"NL"}"#,
        )
        .answers("/freeipapi/203.0.113.7", 200, r#"{"countryCode":"NL"}"#);
    let clock = MovableClock::start();
    let probe = probe_with_clock(&service, &clock);

    let _ = probe.probe(Some("token"));
    clock.advance(CONFIRMATION_SOFT_TTL + std::time::Duration::from_secs(1));
    service.answers_now("/freeipapi/203.0.113.7", 429, "");
    service.answers_now("/geojs/203.0.113.7", 503, "");

    let report = probe.probe(Some("token"));

    assert_eq!(
        report.confirmation,
        SourceOutcome::Answered("NL".to_string())
    );
}

#[test]
fn after_the_hard_ceiling_a_failed_refresh_drops_the_confirmation() {
    let service = FakeGeoService::start()
        .answers(
            "/ipinfo",
            200,
            r#"{"ip":"203.0.113.7","country_code":"NL"}"#,
        )
        .answers("/freeipapi/203.0.113.7", 200, r#"{"countryCode":"NL"}"#);
    let clock = MovableClock::start();
    let probe = probe_with_clock(&service, &clock);

    let _ = probe.probe(Some("token"));
    clock.advance(CONFIRMATION_HARD_TTL + std::time::Duration::from_secs(1));
    service.answers_now("/freeipapi/203.0.113.7", 429, "");
    service.answers_now("/geojs/203.0.113.7", 503, "");

    let report = probe.probe(Some("token"));

    assert_eq!(
        report.confirmation,
        SourceOutcome::Failed(GeoFailure::RateLimited(429)),
        "вечно доверять одному подтверждению нельзя: у переприсвоенных диапазонов страна меняется"
    );
}
