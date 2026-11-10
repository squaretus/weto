//! Токен ipinfo в Диспетчере учётных данных Windows — аналог Keychain.
//!
//! Файлом рядом с настройками токен не хранится: `config.toml` лежит
//! в перемещаемом профиле и уезжает в бэкапы. Учётные данные Windows
//! шифруются DPAPI под пользователем.

use windows_sys::Win32::Foundation::{GetLastError, ERROR_NOT_FOUND, FILETIME};
use windows_sys::Win32::Security::Credentials::{
    CredDeleteW, CredFree, CredReadW, CredWriteW, CREDENTIALW, CRED_PERSIST_LOCAL_MACHINE,
    CRED_TYPE_GENERIC,
};

use weto_sys::secret_store::{SecretError, SecretStoring};

use crate::wide;

/// Имя записи — то же, что сервис Keychain на macOS.
pub const IPINFO_TARGET: &str = "com.weto.ipinfo";

pub struct CredentialStore {
    target: Vec<u16>,
}

impl CredentialStore {
    /// Запись с заданным именем. Приложение берёт `IPINFO_TARGET`, тесты — своё,
    /// чтобы не трогать настоящий токен.
    pub fn new(target: &str) -> CredentialStore {
        CredentialStore {
            target: wide::null_terminated(target),
        }
    }
}

impl SecretStoring for CredentialStore {
    fn load(&self) -> Result<Option<String>, SecretError> {
        let mut credential: *mut CREDENTIALW = std::ptr::null_mut();
        // SAFETY: имя с нулём на конце; результат освобождается `CredFree`.
        let ok = unsafe { CredReadW(self.target.as_ptr(), CRED_TYPE_GENERIC, 0, &mut credential) };
        if ok == 0 {
            // SAFETY: читается сразу после неудачного вызова.
            let error = unsafe { GetLastError() };
            return if error == ERROR_NOT_FOUND {
                Ok(None)
            } else {
                Err(SecretError::Read(format!("CredReadW: код {error}")))
            };
        }
        // SAFETY: `credential` выдан `CredReadW`, блоб — `CredentialBlobSize` байт.
        let token = unsafe {
            let blob = std::slice::from_raw_parts(
                (*credential).CredentialBlob,
                (*credential).CredentialBlobSize as usize,
            );
            let token = String::from_utf8_lossy(blob).into_owned();
            CredFree(credential.cast());
            token
        };
        Ok(Some(token))
    }

    fn save(&self, token: &str) -> Result<(), SecretError> {
        let mut blob = token.as_bytes().to_vec();
        let user = wide::null_terminated("weto");
        let credential = CREDENTIALW {
            Flags: 0,
            Type: CRED_TYPE_GENERIC,
            TargetName: self.target.as_ptr().cast_mut(),
            Comment: std::ptr::null_mut(),
            LastWritten: FILETIME {
                dwLowDateTime: 0,
                dwHighDateTime: 0,
            },
            CredentialBlobSize: blob.len() as u32,
            CredentialBlob: blob.as_mut_ptr(),
            Persist: CRED_PERSIST_LOCAL_MACHINE,
            AttributeCount: 0,
            Attributes: std::ptr::null_mut(),
            TargetAlias: std::ptr::null_mut(),
            UserName: user.as_ptr().cast_mut(),
        };
        // SAFETY: все указатели живы до конца вызова.
        if unsafe { CredWriteW(&credential, 0) } == 0 {
            // SAFETY: читается сразу после неудачного вызова.
            let error = unsafe { GetLastError() };
            return Err(SecretError::Write(format!("CredWriteW: код {error}")));
        }
        Ok(())
    }

    fn delete(&self) -> Result<(), SecretError> {
        // SAFETY: имя с нулём на конце.
        if unsafe { CredDeleteW(self.target.as_ptr(), CRED_TYPE_GENERIC, 0) } == 0 {
            // SAFETY: читается сразу после неудачного вызова.
            let error = unsafe { GetLastError() };
            if error != ERROR_NOT_FOUND {
                return Err(SecretError::Write(format!("CredDeleteW: код {error}")));
            }
        }
        Ok(())
    }
}
