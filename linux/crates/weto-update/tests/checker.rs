//! Опрос релизов на локальном сервере с записанными ответами GitHub.

use std::io::{BufRead, BufReader, Write};
use std::net::TcpListener;

use weto_update::checker::{CheckError, ReleaseChecker};
use weto_update::version::Version;

fn serve(body: &'static str) -> String {
    serve_with_status("200 OK", body)
}

fn serve_with_status(status: &'static str, body: &'static str) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();

    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut line = String::new();
            let _ = reader.read_line(&mut line);
            while reader.read_line(&mut line).map(|n| n > 0).unwrap_or(false) {
                if line.trim().is_empty() {
                    break;
                }
                line.clear();
            }
            let mut stream = stream;
            let head = format!(
                "HTTP/1.1 {status}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                body.len()
            );
            let _ = stream.write_all(head.as_bytes());
            let _ = stream.write_all(body.as_bytes());
        }
    });

    format!("http://127.0.0.1:{port}/latest")
}

fn checker(body: &'static str) -> ReleaseChecker {
    ReleaseChecker::new("squaretus/weto", "x86_64").with_api_url(serve(body))
}

const WITH_ASSET: &str = r#"{
  "tag_name": "v1.2.0",
  "html_url": "https://github.com/squaretus/weto/releases/tag/v1.2.0",
  "body": "Заметки релиза",
  "draft": false,
  "prerelease": false,
  "assets": [
    {"name": "Weto-1.2.0.pkg",
     "browser_download_url": "https://github.com/squaretus/weto/releases/download/v1.2.0/Weto-1.2.0.pkg"},
    {"name": "weto-1.2.0-x86_64-linux.tar.zst",
     "browser_download_url": "https://github.com/squaretus/weto/releases/download/v1.2.0/weto-1.2.0-x86_64-linux.tar.zst"}
  ]
}"#;

#[test]
fn a_newer_release_is_found_with_its_linux_archive() {
    let info = checker(WITH_ASSET)
        .latest(&Version::parse("1.1.0").unwrap())
        .unwrap();

    assert_eq!(info.latest_version, "1.2.0");
    assert!(info.is_newer);
    assert!(info
        .download_url
        .ends_with("weto-1.2.0-x86_64-linux.tar.zst"));
    assert_eq!(
        info.release_url,
        "https://github.com/squaretus/weto/releases/tag/v1.2.0"
    );
    assert_eq!(info.current_version, "1.1.0", "окно говорит «у вас 1.1.0»");
}

/// Ответ без `html_url` всё равно ведёт на страницу релиза — по тегу.
#[test]
fn a_release_without_a_page_link_falls_back_to_the_tag_page() {
    const WITHOUT_PAGE: &str = r#"{
      "tag_name": "v1.2.0", "draft": false, "prerelease": false,
      "assets": [{"name": "weto-1.2.0-x86_64-linux.tar.zst",
                  "browser_download_url": "https://github.com/x/y"}]
    }"#;

    let info = checker(WITHOUT_PAGE)
        .latest(&Version::parse("1.1.0").unwrap())
        .unwrap();

    assert_eq!(
        info.release_url,
        "https://github.com/squaretus/weto/releases/tag/v1.2.0"
    );
}

/// 404 у `releases/latest` — это «релизов пока нет», а не отказ сети:
/// подвал говорит об этом своими словами, как на macOS.
#[test]
fn a_repository_without_releases_is_not_a_network_failure() {
    let checker = ReleaseChecker::new("squaretus/weto", "x86_64").with_api_url(serve_with_status(
        "404 Not Found",
        r#"{"message":"Not Found"}"#,
    ));

    let error = checker
        .latest(&Version::parse("1.1.0").unwrap())
        .unwrap_err();

    assert!(matches!(error, CheckError::NoReleases), "получили: {error}");
}

#[test]
fn the_same_version_is_not_newer() {
    let info = checker(WITH_ASSET)
        .latest(&Version::parse("1.2.0").unwrap())
        .unwrap();

    assert!(!info.is_newer);
}

/// Релиз без архива под нашу платформу — ошибка, а не находка: показать окно,
/// которое ничего не установит, хуже, чем не показать ничего.
#[test]
fn a_release_without_a_linux_archive_is_an_error() {
    const ONLY_PKG: &str = r#"{
      "tag_name": "v1.2.0", "draft": false, "prerelease": false,
      "assets": [{"name": "Weto-1.2.0.pkg", "browser_download_url": "https://github.com/x/y"}]
    }"#;

    let error = checker(ONLY_PKG)
        .latest(&Version::parse("1.1.0").unwrap())
        .unwrap_err();

    assert!(matches!(error, CheckError::NoAsset(_)), "получили: {error}");
}

#[test]
fn drafts_and_prereleases_are_not_offered() {
    const DRAFT: &str = r#"{
      "tag_name": "v9.9.9", "draft": true, "prerelease": false,
      "assets": [{"name": "weto-9.9.9-x86_64-linux.tar.zst",
                  "browser_download_url": "https://github.com/x/y"}]
    }"#;

    assert!(checker(DRAFT)
        .latest(&Version::parse("1.0.0").unwrap())
        .is_err());
}

#[test]
fn a_tag_that_is_not_a_version_is_refused() {
    const WEIRD: &str =
        r#"{"tag_name": "nightly", "draft": false, "prerelease": false, "assets": []}"#;

    assert!(matches!(
        checker(WEIRD).latest(&Version::parse("1.0.0").unwrap()),
        Err(CheckError::Parse(_))
    ));
}

/// Сервер, который соединение принимает и не отвечает ни байтом: так выглядит
/// повисший прокси или канал, где пакеты молча теряются после рукопожатия.
fn serve_silence() -> String {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    std::thread::spawn(move || {
        // Соединения держатся открытыми до конца процесса: закрытое соединение
        // ureq прочёл бы как отказ сразу, и таймаут остался бы непроверенным.
        let mut held = Vec::new();
        for stream in listener.incoming().flatten() {
            held.push(stream);
        }
    });
    format!("http://127.0.0.1:{port}/latest")
}

/// Ручная проверка без таймаута висела вечно: плитка подвала оставалась
/// неактивной, а `check_now` отказывался начинать вторую, пока не кончится
/// первая, — то есть до перезапуска. Молчащий сервер обязан кончаться
/// отказом сети, и за ограниченное время.
#[test]
fn a_server_that_never_answers_ends_the_check_with_a_failure() {
    let checker = ReleaseChecker::new("squaretus/weto", "x86_64")
        .with_api_url(serve_silence())
        .with_timeout(std::time::Duration::from_millis(300));

    let (done, answer) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let _ = done.send(checker.latest(&Version::parse("1.1.0").unwrap()));
    });
    let result = answer
        .recv_timeout(std::time::Duration::from_secs(10))
        .expect("проверка повисла на молчащем сервере");

    assert!(
        matches!(result, Err(CheckError::Request(_))),
        "{:?}",
        result.map(|info| info.latest_version)
    );
}

/// Продуктовый таймаут — общий на весь запрос и ограничен: проверка
/// в фоне раз в час и ручная из подвала не имеют права висеть дольше.
#[test]
fn the_check_timeout_is_bounded() {
    assert_eq!(
        weto_update::checker::CHECK_TIMEOUT,
        std::time::Duration::from_secs(30)
    );
}
