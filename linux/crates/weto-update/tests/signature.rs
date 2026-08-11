//! Проверка подписи на настоящих ключах minisign.
//!
//! Пара ключей и подписанный файл лежат в `tests/fixtures` — сгенерированы
//! один раз тем же minisign, которым CI подписывает релиз. Подделывать подпись
//! в тесте нечем, а проверять надо именно её.

use std::path::PathBuf;

use weto_update::signature::{verify, SignatureError};

fn fixtures() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures")
}

fn public_key(name: &str) -> String {
    std::fs::read_to_string(fixtures().join(name)).expect("ключ на месте")
}

#[test]
fn a_valid_signature_is_accepted() {
    let archive = fixtures().join("archive.tar.zst");
    let signature = fixtures().join("archive.tar.zst.minisig");

    assert_eq!(
        verify(&archive, &signature, &public_key("release.pub")),
        Ok(())
    );
}

/// Подменённый по дороге архив — единственная угроза, которая осталась после
/// отказа от root. Ради неё подпись и проверяется до распаковки.
#[test]
fn a_tampered_archive_is_rejected() {
    let tmp = tempfile::tempdir().unwrap();
    let archive = tmp.path().join("archive.tar.zst");

    let mut bytes = std::fs::read(fixtures().join("archive.tar.zst")).unwrap();
    bytes.push(b'!');
    std::fs::write(&archive, bytes).unwrap();

    assert_eq!(
        verify(
            &archive,
            &fixtures().join("archive.tar.zst.minisig"),
            &public_key("release.pub")
        ),
        Err(SignatureError::Mismatch)
    );
}

/// Валидная подпись чужим ключом — ровно то, что сделает атакующий,
/// подменивший и архив, и подпись.
#[test]
fn a_signature_from_another_key_is_rejected() {
    assert!(verify(
        &fixtures().join("archive.tar.zst"),
        &fixtures().join("archive.tar.zst.minisig"),
        &public_key("other.pub")
    )
    .is_err());
}

#[test]
fn a_missing_signature_is_an_error_not_a_pass() {
    assert!(verify(
        &fixtures().join("archive.tar.zst"),
        &fixtures().join("нет-такого.minisig"),
        &public_key("release.pub")
    )
    .is_err());
}

#[test]
fn a_malformed_signature_is_an_error_not_a_pass() {
    let tmp = tempfile::tempdir().unwrap();
    let signature = tmp.path().join("broken.minisig");
    std::fs::write(&signature, "это не подпись").unwrap();

    assert!(matches!(
        verify(
            &fixtures().join("archive.tar.zst"),
            &signature,
            &public_key("release.pub")
        ),
        Err(SignatureError::Malformed(_))
    ));
}
