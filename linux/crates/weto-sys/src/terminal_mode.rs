//! Режим терминала цели: снять до паузы и вернуть, когда цель снова впереди.
//!
//! Порт `macos/Sources/WetoSystem/TerminalModeKeeper.swift`.
//!
//! Под tmux шелл переднего задания удержать остановленным нельзя: сервер tmux следит
//! за своими детьми-шеллами панелей и тут же продолжает остановленного. Шелл, проснувшись
//! посреди паузы, видит остановку своего задания, печатает `suspended (signal)`, забирает
//! терминал и переключает его режим. Проверено вживую на macOS и Linux — zsh и bash под
//! tmux теряют передний план при любых паузах между сигналами, а на голом pty без tmux
//! порядок «шелл первым» его сохраняет. Программа в сыром режиме, сама его
//! не восстанавливающая (`claude`), после `fg` рисуется, но клавиши до неё не доходят:
//! терминал так и остаётся в режиме шелла, и стрелки печатаются как `^[[B`.
//!
//! Вернуть режим может любой процесс того же пользователя — устройство его, а SIGTTOU
//! грозит только фоновым членам сессии этого терминала, которой weto не принадлежит.

use std::fs::{self, OpenOptions};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{FileTypeExt, MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

/// Режим терминала, снятый с устройства: путь к нему и `termios` как есть.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TerminalMode {
    /// Устройство (`tty_nr` процесса в кодировке ядра) — по нему режим и возвращается.
    pub device: i32,
    /// `/dev/pts/3` — для журнала и ошибок.
    pub path: PathBuf,
    /// Байты `termios`: возвращать структуру нужно целиком — флаги, управляющие
    /// символы и скорость, — а знать её устройство тем, кто режим хранит, незачем.
    pub attributes: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum TerminalModeError {
    #[error("устройство терминала {0} не найдено")]
    NoDevice(i32),
    #[error("терминал {path:?} не открылся: errno {errno}")]
    Open { path: PathBuf, errno: i32 },
    #[error("режим терминала {path:?} не прочитался: errno {errno}")]
    Read { path: PathBuf, errno: i32 },
    #[error("режим терминала {path:?} не записался: errno {errno}")]
    Write { path: PathBuf, errno: i32 },
}

/// Граница возвращает `Result`, а не `bool`: тихий отказ выдавал бы режим
/// за возвращённый.
pub trait TerminalModeKeeping: Send + Sync {
    fn capture(&self, device: i32) -> Result<TerminalMode, TerminalModeError>;
    fn restore(&self, mode: &TerminalMode) -> Result<(), TerminalModeError>;
}

pub struct TerminalModeKeeper;

impl TerminalModeKeeper {
    pub fn new() -> TerminalModeKeeper {
        TerminalModeKeeper
    }
}

impl Default for TerminalModeKeeper {
    fn default() -> Self {
        Self::new()
    }
}

impl TerminalModeKeeping for TerminalModeKeeper {
    fn capture(&self, device: i32) -> Result<TerminalMode, TerminalModeError> {
        let path = path_of(device).ok_or(TerminalModeError::NoDevice(device))?;
        let file = open(&path)?;
        // SAFETY: `termios` — простая структура из чисел, нули в ней допустимы,
        // а заполняет её целиком `tcgetattr`.
        let mut attributes: libc::termios = unsafe { std::mem::zeroed() };
        // SAFETY: дескриптор жив, пока жив `file`; указатель — на локальную структуру.
        if unsafe { libc::tcgetattr(file.as_raw_fd(), &mut attributes) } != 0 {
            return Err(TerminalModeError::Read {
                path,
                errno: last_errno(),
            });
        }
        // SAFETY: читаем ровно `size_of::<termios>()` байт той же структуры.
        let bytes = unsafe {
            std::slice::from_raw_parts(
                (&attributes as *const libc::termios).cast::<u8>(),
                std::mem::size_of::<libc::termios>(),
            )
        }
        .to_vec();
        Ok(TerminalMode {
            device,
            path,
            attributes: bytes,
        })
    }

    fn restore(&self, mode: &TerminalMode) -> Result<(), TerminalModeError> {
        if mode.attributes.len() != std::mem::size_of::<libc::termios>() {
            return Err(TerminalModeError::Write {
                path: mode.path.clone(),
                errno: libc::EINVAL,
            });
        }
        let file = open(&mode.path)?;
        // SAFETY: см. `capture`; длина байтов проверена выше.
        let mut attributes: libc::termios = unsafe { std::mem::zeroed() };
        unsafe {
            std::ptr::copy_nonoverlapping(
                mode.attributes.as_ptr(),
                (&mut attributes as *mut libc::termios).cast::<u8>(),
                mode.attributes.len(),
            );
        }
        // TCSANOW, а не TCSAFLUSH: введённое пользователем после `fg` не выбрасываем.
        // SAFETY: дескриптор жив, пока жив `file`.
        if unsafe { libc::tcsetattr(file.as_raw_fd(), libc::TCSANOW, &attributes) } != 0 {
            return Err(TerminalModeError::Write {
                path: mode.path.clone(),
                errno: last_errno(),
            });
        }
        Ok(())
    }
}

/// `O_NOCTTY`: открытый терминал не должен стать управляющим для weto.
/// `O_NONBLOCK`: открытие не ждёт несущей у модемных линий.
fn open(path: &Path) -> Result<fs::File, TerminalModeError> {
    OpenOptions::new()
        .read(true)
        .write(true)
        .custom_flags(libc::O_NOCTTY | libc::O_NONBLOCK)
        .open(path)
        .map_err(|error| TerminalModeError::Open {
            path: path.to_path_buf(),
            errno: error.raw_os_error().unwrap_or(0),
        })
}

fn last_errno() -> i32 {
    std::io::Error::last_os_error().raw_os_error().unwrap_or(0)
}

/// Major и minor из `tty_nr`. Ядро пишет его через `new_encode_dev`, а не той
/// кодировкой, что glibc отдаёт в `st_rdev`, поэтому сравнивать числа напрямую
/// нельзя: у pty с minor больше 255 они расходятся.
pub fn kernel_device_numbers(device: i32) -> (u32, u32) {
    let encoded = device as u32;
    let major = (encoded >> 8) & 0xfff;
    let minor = (encoded & 0xff) | ((encoded >> 12) & 0xfff00);
    (major, minor)
}

/// Путь символьного устройства по `tty_nr`: `/dev/pts/*` первым — там живут
/// терминалы эмуляторов и tmux, — и `/dev/tty*` как запасной путь для консоли.
pub fn path_of(device: i32) -> Option<PathBuf> {
    if device <= 0 {
        return None;
    }
    let wanted = kernel_device_numbers(device);
    let matches = |path: &Path| -> bool {
        fs::metadata(path).is_ok_and(|meta| {
            meta.file_type().is_char_device()
                && (libc::major(meta.rdev()), libc::minor(meta.rdev())) == wanted
        })
    };

    let pts = fs::read_dir("/dev/pts").into_iter().flatten().flatten();
    let consoles = fs::read_dir("/dev")
        .into_iter()
        .flatten()
        .flatten()
        .filter(|entry| entry.file_name().to_string_lossy().starts_with("tty"));
    pts.chain(consoles)
        .map(|entry| entry.path())
        .find(|path| matches(path))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `tty_nr` первого pty: major 136, minor 0.
    #[test]
    fn the_kernel_encoding_of_a_small_minor_is_major_shifted_by_eight() {
        assert_eq!(kernel_device_numbers(34816), (136, 0));
        assert_eq!(kernel_device_numbers(34816 + 5), (136, 5));
    }

    /// Minor больше 255 ядро уносит в старшие биты: glibc-кодировка тут
    /// разошлась бы с `tty_nr`, и путь не нашёлся бы никогда.
    #[test]
    fn the_kernel_encoding_carries_a_large_minor_in_the_upper_bits() {
        let encoded = (300 & 0xff) | (136 << 8) | ((300 & !0xff) << 12);
        assert_eq!(kernel_device_numbers(encoded), (136, 300));
    }

    #[test]
    fn a_process_without_a_terminal_has_no_device_path() {
        assert_eq!(path_of(0), None);
        assert_eq!(path_of(-1), None);
    }
}
