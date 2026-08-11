//! Опрос релизов на локальном сервере с записанными ответами GitHub.

use std::io::{BufRead, BufReader, Write};
use std::net::TcpListener;

use weto_update::checker::{signature_url, CheckError, ReleaseChecker};
use weto_update::version::Version;

fn serve(body: &'static str) -> String {
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
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
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
    assert_eq!(info.release_notes.as_deref(), Some("Заметки релиза"));
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

#[test]
fn the_signature_lies_next_to_the_archive() {
    assert_eq!(
        signature_url("https://github.com/x/weto-1.0.0-x86_64-linux.tar.zst"),
        "https://github.com/x/weto-1.0.0-x86_64-linux.tar.zst.minisig"
    );
}
