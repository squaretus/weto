//! Проверка подписи архива.
//!
//! На macOS root-демон перепроверял релиз сам, потому что иначе root установил бы
//! то, что попросит любой авторизованный процесс. Без root эта угроза исчезает,
//! но появляется другая: подменённый по дороге архив. Отвечает на неё подпись,
//! и проверяется она **до** распаковки — распаковывать чужое уже поздно.

use std::path::Path;

use minisign_verify::{PublicKey, Signature};

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum SignatureError {
    #[error("подпись не сходится с архивом")]
    Mismatch,
    #[error("подпись не разбирается: {0}")]
    Malformed(String),
    #[error("не прочитать файл: {0}")]
    Read(String),
    #[error("публичный ключ не разбирается: {0}")]
    Key(String),
}

/// Публичный ключ релиза, вшитый при сборке.
///
/// Именно вшитый, а не лежащий файлом рядом: файл подменяется вместе с архивом,
/// и проверка стала бы проверкой архива самим собой.
///
/// `None` означает сборку без ключа — например, локальную. Обновляться такая
/// сборка не имеет права: без ключа проверить подпись нечем, а ставить
/// непроверенное хуже, чем не обновляться вовсе.
pub fn release_public_key() -> Option<&'static str> {
    option_env!("WETO_RELEASE_PUBLIC_KEY")
}

pub fn verify(archive: &Path, signature: &Path, public_key: &str) -> Result<(), SignatureError> {
    // Ключ приходит в виде файла minisign: строка комментария и строка base64.
    // Берём вторую — `from_base64` ждёт именно её.
    let encoded = public_key
        .lines()
        .map(str::trim)
        .rfind(|line| !line.is_empty() && !line.starts_with("untrusted comment:"))
        .ok_or_else(|| SignatureError::Key("в ключе нет строки base64".into()))?;

    let key = PublicKey::from_base64(encoded).map_err(|e| SignatureError::Key(e.to_string()))?;

    let signature_text =
        std::fs::read_to_string(signature).map_err(|e| SignatureError::Read(e.to_string()))?;
    let signature =
        Signature::decode(&signature_text).map_err(|e| SignatureError::Malformed(e.to_string()))?;

    let bytes = std::fs::read(archive).map_err(|e| SignatureError::Read(e.to_string()))?;

    key.verify(&bytes, &signature, false)
        .map_err(|_| SignatureError::Mismatch)
}
