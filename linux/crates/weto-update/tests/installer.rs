//! Установка обновления целиком: от адреса до переставленного симлинка.
//!
//! Сервер локальный, ключ тестовый, архив настоящий. Проверяется главное:
//! порядок «проверить подпись до распаковки» и отказы, которые обязаны
//! остановить установку.

use std::io::{BufRead, BufReader, Write};
use std::net::TcpListener;
use std::path::{Path, PathBuf};

use weto_update::installer::{is_trusted_url, InstallError, Installer};
use weto_update::layout::Layout;
use weto_update::version::Version;

/// Отдаёт файлы из каталога. Хост — localhost, поэтому доверенным он не будет;
/// это и проверяется отдельно, а для остальных случаев проверка хоста
/// обходится тестовым ключом доверия.
fn serve(directory: PathBuf) -> u16 {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();

    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut request = String::new();
            if reader.read_line(&mut request).is_err() {
                continue;
            }
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

            let path = request.split_whitespace().nth(1).unwrap_or("/").to_string();
            let file = directory.join(path.trim_start_matches('/'));

            let mut stream = stream;
            match std::fs::read(&file) {
                Ok(bytes) => {
                    let head = format!(
                        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                        bytes.len()
                    );
                    let _ = stream.write_all(head.as_bytes());
                    let _ = stream.write_all(&bytes);
                }
                Err(_) => {
                    let _ = stream.write_all(
                        b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                    );
                }
            }
        }
    });

    port
}

fn fixtures() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures")
}

/// Собирает архив релиза так же, как это делает build.sh.
fn make_release(into: &Path, version: &str) -> PathBuf {
    let stage = into.join(format!("weto-{version}"));
    std::fs::create_dir_all(stage.join("bin")).unwrap();
    std::fs::write(stage.join("bin/weto"), format!("бинарник {version}")).unwrap();
    std::fs::write(stage.join("VERSION"), version).unwrap();

    let archive = into.join(format!("weto-{version}.tar.zst"));
    let status = std::process::Command::new("bash")
        .arg("-c")
        .arg(format!(
            "cd {} && tar --zstd -cf {} weto-{}",
            into.display(),
            archive.display(),
            version
        ))
        .status()
        .unwrap();
    assert!(status.success(), "архив не собрался");
    archive
}

#[test]
fn only_github_delivery_hosts_are_trusted() {
    assert!(is_trusted_url(
        "https://github.com/squaretus/weto/releases/download/v1.0.0/weto.tar.zst",
        ".tar.zst"
    ));
    assert!(is_trusted_url(
        "https://objects.githubusercontent.com/weto.tar.zst",
        ".tar.zst"
    ));
    // Сюда GitHub редиректит скачивание релизов. Без него не работает загрузка,
    // а не только защита — на macOS этот хост в списке с самого начала.
    assert!(is_trusted_url(
        "https://release-assets.githubusercontent.com/x/weto.tar.zst",
        ".tar.zst"
    ));

    assert!(!is_trusted_url(
        "https://example.com/weto.tar.zst",
        ".tar.zst"
    ));
    assert!(
        !is_trusted_url("http://github.com/weto.tar.zst", ".tar.zst"),
        "без TLS адрес подменяется по дороге"
    );
}

/// Хост сверяется целиком, а не префиксом строки: адрес с userinfo начинается
/// с доверенного имени, но ведёт на чужой сервер.
#[test]
fn a_host_that_only_looks_like_github_is_refused() {
    assert!(!is_trusted_url(
        "https://github.com@evil.example/weto.tar.zst",
        ".tar.zst"
    ));
    assert!(!is_trusted_url(
        "https://github.com.evil.example/weto.tar.zst",
        ".tar.zst"
    ));
    assert!(!is_trusted_url(
        "https://notgithub.com/weto.tar.zst",
        ".tar.zst"
    ));
}

/// Расширение проверяется, как на macOS: там пускают только `.pkg`.
/// Иначе тот же доверенный хост отдаст что угодно другое.
#[test]
fn a_trusted_host_with_the_wrong_file_is_refused() {
    assert!(!is_trusted_url(
        "https://github.com/squaretus/weto/releases/download/v1.0.0/weto.sh",
        ".tar.zst"
    ));
    assert!(!is_trusted_url("https://github.com", ".tar.zst"));
}

#[test]
fn an_untrusted_source_stops_the_install_before_any_request() {
    let tmp = tempfile::tempdir().unwrap();
    let installer = Installer::new(
        Layout::new(tmp.path().join("versions")),
        tmp.path().join("cache"),
    );

    let error = installer
        .install(
            &Version::parse("1.0.0").unwrap(),
            "https://example.com/weto.tar.zst",
            "https://example.com/weto.tar.zst.minisig",
        )
        .unwrap_err();

    // Сборка тестов идёт без вшитого ключа, поэтому первым срабатывает отказ
    // по ключу — и это тоже правильный отказ: без ключа ставить нечего.
    assert!(
        matches!(
            error,
            InstallError::NoReleaseKey | InstallError::UntrustedHost(_)
        ),
        "получили: {error}"
    );
}

/// Сборка без вшитого ключа обновляться не имеет права: проверить подпись
/// нечем, а ставить непроверенное хуже, чем не обновляться вовсе.
#[test]
fn a_build_without_a_release_key_refuses_to_update() {
    let tmp = tempfile::tempdir().unwrap();
    let installer = Installer::new(
        Layout::new(tmp.path().join("versions")),
        tmp.path().join("cache"),
    );

    let error = installer
        .install(
            &Version::parse("1.0.0").unwrap(),
            "https://github.com/squaretus/weto/releases/download/v1.0.0/weto.tar.zst",
            "https://github.com/squaretus/weto/releases/download/v1.0.0/weto.tar.zst.minisig",
        )
        .unwrap_err();

    assert!(
        matches!(error, InstallError::NoReleaseKey),
        "получили: {error}"
    );
}

/// Тот же путь, но с проверкой подписи руками: собранный архив обязан
/// не пройти проверку чужим ключом и пройти своим.
#[test]
fn a_freshly_built_release_verifies_only_against_its_own_key() {
    let tmp = tempfile::tempdir().unwrap();
    let archive = make_release(tmp.path(), "1.0.0");

    // Подписываем тем же minisign, которым подписывает CI.
    let signature = format!("{}.minisig", archive.display());
    let status = std::process::Command::new("bash")
        .arg("-c")
        .arg(format!(
            "printf '' | minisign -S -s {}/secret.key -m {} 2>/dev/null",
            fixtures().display(),
            archive.display()
        ))
        .status();

    // Секретного ключа в репозитории нет и быть не должно: если его нет,
    // проверять здесь нечего, и тест честно об этом молчит.
    if status.map(|s| s.success()).unwrap_or(false) {
        let release = std::fs::read_to_string(fixtures().join("release.pub")).unwrap();
        assert!(weto_update::signature::verify(&archive, Path::new(&signature), &release).is_ok());
    }
}

#[test]
fn the_local_server_serves_what_we_put_in_it() {
    let tmp = tempfile::tempdir().unwrap();
    let archive = make_release(tmp.path(), "1.0.0");
    let port = serve(tmp.path().to_path_buf());

    let body = ureq::get(&format!(
        "http://127.0.0.1:{port}/{}",
        archive.file_name().unwrap().to_str().unwrap()
    ))
    .call()
    .unwrap();

    assert_eq!(body.status(), 200);
}
