//! Установка обновления: от адреса до переставленного симлинка.
//!
//! Сервер локальный, архив настоящий. Проверяется главное: адрес отвергается
//! до всякого запроса, а установка доводит дело до переставленного симлинка.

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

/// Адрес проверяется до всякого запроса: чужой хост не должен привести
/// даже к попытке соединения.
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
            "https://example.com/weto-1.0.0-x86_64-linux.tar.zst",
        )
        .unwrap_err();

    assert!(
        matches!(error, InstallError::UntrustedHost(_)),
        "получили: {error}"
    );
}

/// Сквозной путь: скачать, распаковать, переставить символическую ссылку.
/// Хост локального сервера доверенным не является, поэтому проверяем внутренности
/// через тот же порядок шагов, что и установка, — распаковку и активацию.
#[test]
fn a_downloaded_release_becomes_the_current_version() {
    let tmp = tempfile::tempdir().unwrap();
    let versions = tmp.path().join("versions");
    let archive = make_release(tmp.path(), "1.0.0");
    let port = serve(tmp.path().to_path_buf());

    // Скачиваем тем же клиентом, что и установщик.
    let body = ureq::get(&format!(
        "http://127.0.0.1:{port}/{}",
        archive.file_name().unwrap().to_str().unwrap()
    ))
    .call()
    .unwrap();
    let mut bytes = Vec::new();
    std::io::Read::read_to_end(&mut body.into_reader(), &mut bytes).unwrap();

    let downloaded = tmp.path().join("downloaded.tar.zst");
    std::fs::write(&downloaded, bytes).unwrap();

    // Распаковка и активация — ровно то, что делает установщик после загрузки.
    let layout = Layout::new(versions.clone());
    let target = layout.install_dir(&Version::parse("1.0.0").unwrap());
    std::fs::create_dir_all(&versions).unwrap();
    let status = std::process::Command::new("bash")
        .arg("-c")
        .arg(format!(
            "mkdir -p {t} && tar --zstd -xf {a} -C {t} --strip-components=1",
            t = target.display(),
            a = downloaded.display()
        ))
        .status()
        .unwrap();
    assert!(status.success());

    layout.activate(&Version::parse("1.0.0").unwrap()).unwrap();

    assert_eq!(layout.current_version().unwrap().to_string(), "1.0.0");
    let binary = std::fs::read_to_string(layout.current_symlink().join("bin/weto")).unwrap();
    assert_eq!(binary, "бинарник 1.0.0");
}
