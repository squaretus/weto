//! Режим терминала на настоящем pty: граница работает с устройством ядра,
//! и подменять тут нечего.
//!
//! Порт `macos/Tests/WetoSystemTests/TerminalModeKeeperTests.swift`. Номер устройства
//! берётся не из `st_rdev`, а у живого процесса, для которого pty — управляющий
//! терминал: ядро пишет `tty_nr` своей кодировкой, и найти путь по нему — ровно то,
//! что граница обязана уметь.

use std::os::unix::process::CommandExt;
use std::process::{Child, Command};

use weto_sys::process_registry::{ProcRegistry, ProcessRegistryReading};
use weto_sys::terminal_mode::{TerminalModeError, TerminalModeKeeper, TerminalModeKeeping};

struct Pty {
    master: i32,
    slave: i32,
}

impl Pty {
    fn open() -> Pty {
        let mut master = -1;
        let mut slave = -1;
        let opened = unsafe {
            libc::openpty(
                &mut master,
                &mut slave,
                std::ptr::null_mut(),
                std::ptr::null(),
                std::ptr::null(),
            )
        };
        assert_eq!(opened, 0, "pty не открылся");
        Pty { master, slave }
    }

    fn local_flags(&self) -> libc::tcflag_t {
        let mut attributes: libc::termios = unsafe { std::mem::zeroed() };
        assert_eq!(unsafe { libc::tcgetattr(self.slave, &mut attributes) }, 0);
        attributes.c_lflag
    }

    fn set_local_flags(&self, raw: bool) {
        let mut attributes: libc::termios = unsafe { std::mem::zeroed() };
        assert_eq!(unsafe { libc::tcgetattr(self.slave, &mut attributes) }, 0);
        let flags = libc::ICANON | libc::ECHO | libc::ISIG | libc::IEXTEN;
        if raw {
            attributes.c_lflag &= !flags;
        } else {
            attributes.c_lflag |= flags;
        }
        assert_eq!(
            unsafe { libc::tcsetattr(self.slave, libc::TCSANOW, &attributes) },
            0
        );
    }
}

impl Drop for Pty {
    fn drop(&mut self) {
        unsafe {
            libc::close(self.master);
            libc::close(self.slave);
        }
    }
}

/// Процесс, для которого pty — управляющий терминал: своя сессия и `TIOCSCTTY`.
struct Session(Child);

impl Session {
    fn on(pty: &Pty) -> Session {
        let slave = pty.slave;
        let mut command = Command::new("sleep");
        command.arg("86404");
        unsafe {
            command.pre_exec(move || {
                if libc::setsid() < 0 || libc::ioctl(slave, libc::TIOCSCTTY, 0) < 0 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
        Session(command.spawn().expect("sleep запустился"))
    }

    /// `tty_nr` из `/proc` — ровно то число, что приходит границе из обхода.
    fn terminal_device(&self) -> i32 {
        let pid = self.0.id() as i32;
        ProcRegistry::new()
            .snapshot()
            .into_iter()
            .find(|process| process.pid == pid)
            .expect("реестр видит процесс")
            .terminal_device
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

/// Ровно то, что случается с `claude`: сырой режим до паузы, режим шелла после неё,
/// и сырой режим обратно — снаружи, по одному номеру устройства из `/proc`.
#[test]
fn the_raw_mode_captured_before_the_pause_comes_back_after_the_shell_changed_it() {
    let pty = Pty::open();
    let session = Session::on(&pty);
    let device = session.terminal_device();
    assert_ne!(device, 0, "у процесса есть управляющий терминал");

    pty.set_local_flags(true);
    let keeper = TerminalModeKeeper::new();
    let mode = keeper.capture(device).expect("режим снят");
    assert!(
        mode.path.starts_with("/dev/pts/"),
        "путь устройства: {:?}",
        mode.path
    );

    pty.set_local_flags(false);
    assert_ne!(
        pty.local_flags() & libc::ICANON,
        0,
        "шелл вернул построчный режим"
    );

    keeper.restore(&mode).expect("режим вернулся");
    let flags = pty.local_flags();
    assert_eq!(flags & libc::ICANON, 0, "сырой режим вернулся");
    assert_eq!(
        flags & libc::ECHO,
        0,
        "эха нет — клавиши не печатаются поверх интерфейса"
    );
    assert_eq!(flags & libc::ISIG, 0);
    assert_eq!(flags & libc::IEXTEN, 0);
}

#[test]
fn a_process_without_a_terminal_has_nothing_to_capture() {
    let keeper = TerminalModeKeeper::new();
    assert_eq!(keeper.capture(0), Err(TerminalModeError::NoDevice(0)));
    assert_eq!(keeper.capture(-1), Err(TerminalModeError::NoDevice(-1)));
}
