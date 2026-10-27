//! Обновление: `weto update check | install` против подделанной сети
//! и подделанного каталога бинарника, разбор `SHA256SUMS` и архива, замена
//! файла на настоящем диске и суточная проверка работающей охраны.

mod support;

use std::time::{Duration, SystemTime};

use support::{now, Bench};
use weto_cli::update::{
    asset_name, checksum_for, extract_binary, replace_file, sha256_hex, Check, FetchError,
    UpdateWatch, LATEST_RELEASE_URL, SUMS_ASSET,
};
use weto_update::version::Version;

const DOWNLOADS: &str = "https://github.com/squaretus/weto/releases/download/v0.3.0";

fn v(text: &str) -> Version {
    Version::parse(text).unwrap()
}

/// Архив, как его собирает `build.sh`: один файл `weto`.
fn archive_with(name: &str, contents: &[u8]) -> Vec<u8> {
    let mut builder = tar::Builder::new(flate2::write::GzEncoder::new(
        Vec::new(),
        flate2::Compression::default(),
    ));
    let mut header = tar::Header::new_gnu();
    header.set_size(contents.len() as u64);
    header.set_mode(0o755);
    header.set_cksum();
    builder.append_data(&mut header, name, contents).unwrap();
    builder.into_inner().unwrap().finish().unwrap()
}

fn release_json(tag: &str, assets: &[(&str, &str)]) -> Vec<u8> {
    let assets: Vec<serde_json::Value> = assets
        .iter()
        .map(|(name, url)| serde_json::json!({ "name": name, "browser_download_url": url }))
        .collect();
    serde_json::json!({ "tag_name": tag, "assets": assets })
        .to_string()
        .into_bytes()
}

/// Релиз 0.3.0 с архивом под эту машину и суммами к нему.
struct Published {
    archive_url: String,
    sums_url: String,
    binary: Vec<u8>,
}

fn publish(bench: &Bench) -> Published {
    let name = asset_name(&v("0.3.0"));
    let binary = b"\x7fELF new weto".to_vec();
    let archive = archive_with("weto", &binary);
    let archive_url = format!("{DOWNLOADS}/{name}");
    let sums_url = format!("{DOWNLOADS}/{SUMS_ASSET}");
    bench.releases.answers(
        LATEST_RELEASE_URL,
        Ok(release_json(
            "v0.3.0",
            &[(&name, &archive_url), (SUMS_ASSET, &sums_url)],
        )),
    );
    bench.releases.answers(
        &sums_url,
        Ok(format!(
            "{}  weto-0.3.0-x86_64-linux.tar.zst\n{}  {name}\n",
            "0".repeat(64),
            sha256_hex(&archive)
        )
        .into_bytes()),
    );
    bench.releases.answers(&archive_url, Ok(archive));
    Published {
        archive_url,
        sums_url,
        binary,
    }
}

/// Стенд, чей бинарник лежит на диске: путь замены — после разворота симлинков.
fn bench_with_binary() -> Bench {
    let mut bench = Bench::new();
    let path = bench.script("weto");
    bench.ctx.identity.executable = Ok(path.into());
    bench
}

// --- проверка -----------------------------------------------------------------

#[test]
fn check_names_the_newer_version() {
    let bench = Bench::new();
    publish(&bench);

    let output = bench.run(&["update", "check"]);

    assert_eq!(output.code, 0, "{}", output.err);
    assert_eq!(
        output.out,
        "установлена 0.2.0, доступна 0.3.0: sudo weto update\n"
    );
    assert_eq!(bench.releases.requested(), [LATEST_RELEASE_URL]);
}

#[test]
fn check_says_when_the_latest_is_installed() {
    let mut bench = Bench::new();
    publish(&bench);
    bench.ctx.version = "0.3.0".to_string();

    let output = bench.run(&["update", "check"]);

    assert_eq!(output.code, 0);
    assert_eq!(output.out, "установлена последняя версия 0.3.0\n");
}

/// Сборка без версии сравнивать не с чем — и в сеть не ходит.
#[test]
fn a_build_without_a_version_refuses_to_compare() {
    for version in ["dev", "0.0.0"] {
        let mut bench = Bench::new();
        bench.ctx.version = version.to_string();

        for words in [&["update", "check"][..], &["update"]] {
            let output = bench.run(words);
            assert_eq!(output.code, 1, "{version} {words:?}");
            assert_eq!(
                output.err,
                "версия этой сборки неизвестна — сравнивать не с чем\n"
            );
        }
        assert!(bench.releases.requested().is_empty());
    }
}

#[test]
fn an_unreachable_feed_is_an_error() {
    let bench = Bench::new();
    bench
        .releases
        .answers(LATEST_RELEASE_URL, Err(FetchError::NotFound));

    let output = bench.run(&["update", "check"]);

    assert_eq!(output.code, 1);
    assert_eq!(
        output.err,
        "не удалось проверить обновления: релизов пока нет\n"
    );
}

// --- установка ---------------------------------------------------------------------

/// `weto update` без действия — установка: скачать, сверить сумму, заменить
/// файл, назвать версии.
#[test]
fn update_replaces_the_binary_with_the_verified_one() {
    let bench = bench_with_binary();
    let published = publish(&bench);

    let output = bench.run(&["update"]);

    assert_eq!(output.code, 0, "{}", output.err);
    assert_eq!(output.out, "обновлено: 0.2.0 → 0.3.0\n");
    let replaced = bench.binary.replaced.lock().unwrap().clone();
    let executable = bench.ctx.identity.executable.clone().unwrap();
    assert_eq!(replaced, [(executable, published.binary)]);
    assert_eq!(
        bench.releases.requested(),
        [
            LATEST_RELEASE_URL.to_string(),
            published.sums_url,
            published.archive_url
        ]
    );
    assert!(
        bench.commands.calls().is_empty(),
        "сервиса нет — перезапускать нечего"
    );
}

/// Запущенный сервис перезапускается: штатный выход охраны продолжает
/// стоящие цели, новый экземпляр подхватывает учёт.
#[test]
fn a_running_service_is_restarted_after_the_update() {
    let bench = bench_with_binary();
    publish(&bench);
    let unit = bench.ctx.identity.user_unit_dir.join("weto.service");
    std::fs::create_dir_all(unit.parent().unwrap()).unwrap();
    std::fs::write(&unit, "").unwrap();
    bench
        .commands
        .answers("systemctl --user is-active", true, "active");

    let output = bench.run(&["update", "install"]);

    assert_eq!(output.code, 0, "{}", output.err);
    assert_eq!(
        bench.commands.calls(),
        [
            "systemctl --user is-active weto.service",
            "systemctl --user restart weto.service",
        ]
    );
    assert_eq!(
        output.out,
        "обновлено: 0.2.0 → 0.3.0\nсервис перезапущен: weto.service\n"
    );
}

/// Установленный, но остановленный сервис не поднимается: его остановил
/// пользователь.
#[test]
fn a_stopped_service_stays_stopped() {
    let bench = bench_with_binary();
    publish(&bench);
    let unit = bench.ctx.identity.user_unit_dir.join("weto.service");
    std::fs::create_dir_all(unit.parent().unwrap()).unwrap();
    std::fs::write(&unit, "").unwrap();
    bench
        .commands
        .answers("systemctl --user is-active", false, "inactive");

    assert_eq!(bench.run(&["update"]).code, 0);
    assert_eq!(
        bench.commands.calls(),
        ["systemctl --user is-active weto.service"]
    );
}

#[test]
fn no_rights_on_the_binary_directory_stops_before_the_network() {
    let bench = bench_with_binary();
    *bench.binary.writable.lock().unwrap() = false;

    let output = bench.run(&["update"]);

    assert_eq!(output.code, 1);
    assert_eq!(output.err, "нужны права: sudo weto update\n");
    assert!(bench.releases.requested().is_empty());
}

#[test]
fn the_latest_version_is_not_reinstalled() {
    let mut bench = bench_with_binary();
    publish(&bench);
    bench.ctx.version = "0.3.0".to_string();

    let output = bench.run(&["update"]);

    assert_eq!(output.code, 0);
    assert_eq!(output.out, "установлена последняя версия 0.3.0\n");
    assert!(bench.binary.replaced.lock().unwrap().is_empty());
}

/// Отказ установки — канон дословно, код 1, бинарник не тронут.
fn refused(bench: &Bench, expected: &str) {
    let output = bench.run(&["update"]);
    assert_eq!(output.code, 1, "{}", output.out);
    assert_eq!(output.err, format!("{expected}\n"));
    assert!(output.out.is_empty(), "{}", output.out);
    assert!(bench.binary.replaced.lock().unwrap().is_empty());
}

#[test]
fn a_checksum_mismatch_replaces_nothing() {
    let bench = bench_with_binary();
    let published = publish(&bench);
    let name = asset_name(&v("0.3.0"));
    bench.releases.bodies.lock().unwrap().insert(
        0,
        (
            published.sums_url,
            Ok(format!("{}  {name}\n", "a".repeat(64)).into_bytes()),
        ),
    );

    refused(
        &bench,
        &format!("контрольная сумма {name} не совпала с SHA256SUMS — ничего не заменено"),
    );
}

#[test]
fn sums_without_our_archive_replace_nothing() {
    let bench = bench_with_binary();
    let published = publish(&bench);
    let name = asset_name(&v("0.3.0"));
    bench.releases.bodies.lock().unwrap().insert(
        0,
        (
            published.sums_url,
            Ok(format!("{}  другое.tar.gz\n", "a".repeat(64)).into_bytes()),
        ),
    );

    refused(
        &bench,
        &format!("в SHA256SUMS нет суммы для {name} — ничего не заменено"),
    );
}

#[test]
fn a_release_without_sums_replaces_nothing() {
    let bench = bench_with_binary();
    let name = asset_name(&v("0.3.0"));
    bench.releases.answers(
        LATEST_RELEASE_URL,
        Ok(release_json(
            "v0.3.0",
            &[(&name, &format!("{DOWNLOADS}/{name}"))],
        )),
    );

    refused(
        &bench,
        "в релизе 0.3.0 нет SHA256SUMS — без контрольной суммы ничего не заменено",
    );
    assert_eq!(bench.releases.requested(), [LATEST_RELEASE_URL]);
}

/// Последний релиз — приложение без терминальной версии: `update check`
/// так и говорит (код 0), установка отказывает (код 1).
#[test]
fn a_release_without_our_archive_is_not_an_update() {
    let bench = bench_with_binary();
    bench.releases.answers(
        LATEST_RELEASE_URL,
        Ok(release_json(
            "v1.15.0",
            &[(
                "weto-1.15.0-x86_64-linux.tar.zst",
                &format!("{DOWNLOADS}/weto-1.15.0-x86_64-linux.tar.zst"),
            )],
        )),
    );

    let check = bench.run(&["update", "check"]);
    assert_eq!(check.code, 0);
    assert_eq!(
        check.out,
        "в последнем релизе 1.15.0 нет терминальной версии для этой системы\n"
    );

    refused(
        &bench,
        &format!(
            "в релизе 1.15.0 нет файла {} — ничего не заменено",
            asset_name(&v("1.15.0"))
        ),
    );
    assert_eq!(
        bench.releases.requested(),
        [LATEST_RELEASE_URL, LATEST_RELEASE_URL],
        "за архивом не ходили"
    );
}

/// Ссылка из ответа API — только https и только хосты доставки GitHub:
/// подменённый ответ не уведёт загрузку на чужой файл.
#[test]
fn an_untrusted_link_is_never_fetched() {
    let bench = bench_with_binary();
    let name = asset_name(&v("0.3.0"));
    let evil = format!("https://github.com@evil.example/{name}");
    bench.releases.answers(
        LATEST_RELEASE_URL,
        Ok(release_json(
            "v0.3.0",
            &[
                (&name, &evil),
                (SUMS_ASSET, &format!("{DOWNLOADS}/{SUMS_ASSET}")),
            ],
        )),
    );

    refused(
        &bench,
        &format!("ссылка на {name} ведёт не на GitHub — ничего не заменено"),
    );
    assert_eq!(bench.releases.requested(), [LATEST_RELEASE_URL]);
}

#[test]
fn a_failed_download_replaces_nothing() {
    let bench = bench_with_binary();
    let published = publish(&bench);
    bench.releases.bodies.lock().unwrap().insert(
        0,
        (
            published.archive_url,
            Err(FetchError::Failed("соединение сброшено".to_string())),
        ),
    );

    refused(
        &bench,
        &format!(
            "не удалось скачать {}: соединение сброшено — ничего не заменено",
            asset_name(&v("0.3.0"))
        ),
    );
}

/// Архив с чужим содержимым: сумма сошлась (архив тот, что выложен),
/// но бинарника `weto` в нём одного нет.
#[test]
fn an_archive_without_weto_alone_replaces_nothing() {
    let bench = bench_with_binary();
    let published = publish(&bench);
    let name = asset_name(&v("0.3.0"));
    let wrong = archive_with("weto-cli", b"binary");
    let mut bodies = bench.releases.bodies.lock().unwrap();
    bodies.insert(0, (published.archive_url, Ok(wrong.clone())));
    bodies.insert(
        0,
        (
            published.sums_url,
            Ok(format!("{}  {name}\n", sha256_hex(&wrong)).into_bytes()),
        ),
    );
    drop(bodies);

    refused(
        &bench,
        &format!(
            "архив {name} не годится: внутри должен быть ровно один файл weto, \
             а там: weto-cli — ничего не заменено"
        ),
    );
}

#[test]
fn a_failed_replacement_is_named() {
    let mut bench = bench_with_binary();
    publish(&bench);
    bench.ctx.identity.executable = Err("нет /proc/self/exe".to_string());

    let output = bench.run(&["update"]);

    assert_eq!(output.code, 1);
    assert_eq!(
        output.err,
        "не удалось заменить бинарник: нет /proc/self/exe\n"
    );
}

// --- разбор ---------------------------------------------------------------------

#[test]
fn sums_are_read_in_both_sha256sum_modes_and_by_the_whole_name() {
    let hash = "AB".repeat(32);
    let sums = format!(
        "{hash}  weto-cli-0.3.0-linux-x86_64.tar.gz.sig\n{hash} *weto-cli-0.3.0-linux-x86_64.tar.gz\n"
    );

    assert_eq!(
        checksum_for(&sums, "weto-cli-0.3.0-linux-x86_64.tar.gz"),
        Some("ab".repeat(32))
    );
    assert_eq!(checksum_for(&sums, "weto-cli-0.3.0-linux"), None);
    assert_eq!(checksum_for("abc  name\n", "name"), None, "не sha256");
}

/// Внутри — ровно один файл `weto`; деталь отказа — канон обеих платформ.
#[test]
fn the_archive_must_hold_weto_alone() {
    assert_eq!(
        extract_binary(&archive_with("./weto", b"binary")).unwrap(),
        b"binary"
    );
    assert_eq!(
        extract_binary(&archive_with("weto-cli", b"binary")),
        Err("внутри должен быть ровно один файл weto, а там: weto-cli".to_string())
    );
    assert_eq!(
        extract_binary(&archive_with("weto", b"")),
        Err("файл weto пустой".to_string())
    );
    assert_eq!(
        extract_binary(b"not a gzip"),
        Err("tar не прочитал архив".to_string())
    );

    let mut builder = tar::Builder::new(flate2::write::GzEncoder::new(
        Vec::new(),
        flate2::Compression::default(),
    ));
    for name in ["weto", "README"] {
        let mut header = tar::Header::new_gnu();
        header.set_size(1);
        header.set_cksum();
        builder.append_data(&mut header, name, &b"x"[..]).unwrap();
    }
    let two = builder.into_inner().unwrap().finish().unwrap();
    assert_eq!(
        extract_binary(&two),
        Err("внутри должен быть ровно один файл weto, а там: weto, README".to_string())
    );
}

#[test]
fn the_asset_is_named_by_version_and_machine() {
    assert_eq!(
        asset_name(&v("0.3.0")),
        format!("weto-cli-0.3.0-linux-{}.tar.gz", std::env::consts::ARCH)
    );
}

/// Замена на настоящем диске: новый файл `0755` на месте старого, без
/// временного `.weto.new` рядом; открытый старый файл доживает своё.
#[test]
fn replacing_the_binary_is_a_rename_over_it() {
    use std::io::Read;
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("weto");
    std::fs::write(&path, b"old").unwrap();
    let mut running = std::fs::File::open(&path).unwrap();

    replace_file(&path, b"new").unwrap();

    assert_eq!(std::fs::read(&path).unwrap(), b"new");
    assert_eq!(
        std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
        0o755
    );
    assert!(!dir.path().join(".weto.new").exists());
    let mut old = String::new();
    running.read_to_string(&mut old).unwrap();
    assert_eq!(old, "old", "работающий процесс держит прежний inode");
}

// --- суточная проверка ------------------------------------------------------------

fn newer(version: &str) -> Result<Check, String> {
    Ok(Check::Newer {
        current: v("0.2.0"),
        latest: weto_cli::update::Release {
            version: v(version),
            assets: Vec::new(),
        },
    })
}

/// Новая версия называется в логе один раз, в статусе — пока она есть.
#[test]
fn the_watch_announces_each_version_once() {
    let mut watch = UpdateWatch::new();
    let start = now();

    assert_eq!(
        watch.record(newer("0.3.0"), start),
        Some("доступна версия 0.3.0: sudo weto update".to_string())
    );
    assert_eq!(watch.available().as_deref(), Some("0.3.0"));
    assert_eq!(watch.record(newer("0.3.0"), start + DAY), None);
    assert_eq!(
        watch.record(newer("0.4.0"), start + 2 * DAY),
        Some("доступна версия 0.4.0: sudo weto update".to_string())
    );
    assert_eq!(watch.record(Ok(Check::UpToDate(v("0.4.0"))), start), None);
    assert_eq!(watch.available(), None);

    // Релиз без терминальной версии для этой системы — не обновление.
    assert_eq!(
        watch.record(Ok(Check::WithoutOurAsset(v("1.15.0"))), start),
        None
    );
    assert_eq!(watch.available(), None);
}

const DAY: Duration = Duration::from_secs(24 * 3600);

/// Сеть недоступна — одна строка на серию отказов, не чаще раза в сутки;
/// найденная раньше версия при отказе из статуса не пропадает.
#[test]
fn the_watch_logs_failures_at_most_daily() {
    let mut watch = UpdateWatch::new();
    let start: SystemTime = now();
    watch.record(newer("0.3.0"), start);

    let failed = || Err::<Check, String>("сеть недоступна".to_string());
    assert_eq!(
        watch.record(failed(), start),
        Some("не удалось проверить обновления: сеть недоступна".to_string())
    );
    assert_eq!(watch.record(failed(), start + DAY / 2), None);
    assert!(watch.record(failed(), start + DAY).is_some());
    assert_eq!(watch.available().as_deref(), Some("0.3.0"));

    watch.record(newer("0.3.0"), start + 2 * DAY);
    assert!(
        watch.record(failed(), start + 2 * DAY).is_some(),
        "успех начинает новую серию"
    );
}
