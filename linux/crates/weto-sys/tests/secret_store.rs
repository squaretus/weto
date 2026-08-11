//! Хранилище секрета: права, отсутствие файла, честная ошибка.

use std::os::unix::fs::PermissionsExt;

use weto_sys::secret_store::{FileSecretStore, SecretStoring};

#[test]
fn written_secret_is_read_back() {
    let tmp = tempfile::tempdir().unwrap();
    let store = FileSecretStore::new(tmp.path().join("weto/token"));

    store.save("секретный-токен").unwrap();

    assert_eq!(store.load().unwrap().as_deref(), Some("секретный-токен"));
}

/// Файл читается любым процессом пользователя, если права не сузить.
/// Ради этого токен и не живёт в конфиге.
#[test]
fn the_secret_file_is_readable_only_by_its_owner() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("weto/token");
    FileSecretStore::new(path.clone()).save("токен").unwrap();

    let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode, 0o600, "права файла: {mode:o}");

    let dir_mode = std::fs::metadata(path.parent().unwrap())
        .unwrap()
        .permissions()
        .mode()
        & 0o777;
    assert_eq!(dir_mode, 0o700, "права каталога: {dir_mode:o}");
}

/// Файл мог остаться от прежней версии с широкими правами — перезапись
/// обязана их сузить, а не унаследовать.
#[test]
fn an_existing_world_readable_file_gets_its_permissions_tightened() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("token");
    std::fs::write(&path, "старый").unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();

    FileSecretStore::new(path.clone()).save("новый").unwrap();

    let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode, 0o600);
}

#[test]
fn a_missing_secret_is_absence_not_an_error() {
    let tmp = tempfile::tempdir().unwrap();
    let store = FileSecretStore::new(tmp.path().join("нет-такого"));

    assert_eq!(store.load().unwrap(), None);
}

#[test]
fn an_empty_file_counts_as_no_secret() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("token");
    std::fs::write(&path, "  \n").unwrap();

    assert_eq!(FileSecretStore::new(path).load().unwrap(), None);
}

/// Тихая ошибка записи выдавала бы токен за сохранённый — на macOS этот урок
/// уже оплачен.
#[test]
fn a_failed_write_is_reported_not_swallowed() {
    let store = FileSecretStore::new("/proc/недоступно/token".into());

    assert!(store.save("токен").is_err());
}

#[test]
fn deleting_a_missing_secret_is_not_an_error() {
    let tmp = tempfile::tempdir().unwrap();
    let store = FileSecretStore::new(tmp.path().join("token"));

    store.save("токен").unwrap();
    store.delete().unwrap();
    store.delete().unwrap();

    assert_eq!(store.load().unwrap(), None);
}
