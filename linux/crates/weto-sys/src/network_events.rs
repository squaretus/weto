//! Мгновенное уведомление о том, что сеть изменилась.
//!
//! Замена макосному `NWPathMonitor` и нотификациям `SCDynamicStore`. Без него
//! падение туннеля замечалось бы только очередным тиком охраны — до пяти секунд
//! трафика мимо VPN.
//!
//! Содержимое сообщений не разбирается намеренно: любое из них означает лишь
//! «снимок мог измениться», а что именно изменилось, расскажет
//! `NetworkSnapshotReading`. Так граница остаётся тонкой, а разбор структур
//! ядра не расползается по адаптерам.

use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::Arc;

pub trait NetworkEventSourcing: Send + Sync {
    /// Канал, в который приходит сигнал на каждое изменение сети.
    fn subscribe(&self) -> Receiver<()>;
}

/// Группы, на которые подписываемся: появление и исчезновение интерфейсов,
/// смена адресов и смена маршрутов обеих версий IP. Правила (`ip rule`)
/// отдельной группы не имеют, но их правка всегда сопровождается изменением
/// маршрутов, так что окно не остаётся.
const RTMGRP_LINK: u32 = 0x1;
const RTMGRP_IPV4_IFADDR: u32 = 0x10;
const RTMGRP_IPV4_ROUTE: u32 = 0x40;
const RTMGRP_IPV6_IFADDR: u32 = 0x100;
const RTMGRP_IPV6_ROUTE: u32 = 0x400;

pub struct NetlinkEventSource;

impl NetworkEventSourcing for NetlinkEventSource {
    fn subscribe(&self) -> Receiver<()> {
        let (sender, receiver) = mpsc::channel();
        let sender = Arc::new(sender);

        std::thread::Builder::new()
            .name("weto-netlink".to_string())
            .spawn(move || listen(&sender))
            .expect("поток подписки на netlink не создался");

        receiver
    }
}

fn listen(sender: &Sender<()>) {
    let Some(socket) = NetlinkSocket::open() else {
        // Без сокета остаётся только штатный тик охраны: он реже, но безопасен.
        eprintln!("weto: подписка на события сети недоступна, работаем по таймеру");
        return;
    };

    let mut buffer = [0u8; 8192];
    loop {
        match socket.read(&mut buffer) {
            // Отправитель исчез — некому слушать, поток больше не нужен.
            Ok(_) => {
                if sender.send(()).is_err() {
                    return;
                }
            }
            Err(_) => return,
        }
    }
}

struct NetlinkSocket {
    fd: i32,
}

impl NetlinkSocket {
    fn open() -> Option<NetlinkSocket> {
        // SAFETY: обычная последовательность socket + bind. Все структуры
        // заполняются целиком, размеры берутся у самих типов.
        unsafe {
            let fd = libc::socket(
                libc::AF_NETLINK,
                libc::SOCK_RAW | libc::SOCK_CLOEXEC,
                libc::NETLINK_ROUTE,
            );
            if fd < 0 {
                return None;
            }

            let mut address: libc::sockaddr_nl = std::mem::zeroed();
            address.nl_family = libc::AF_NETLINK as u16;
            address.nl_groups = RTMGRP_LINK
                | RTMGRP_IPV4_IFADDR
                | RTMGRP_IPV4_ROUTE
                | RTMGRP_IPV6_IFADDR
                | RTMGRP_IPV6_ROUTE;

            let bound = libc::bind(
                fd,
                &address as *const libc::sockaddr_nl as *const libc::sockaddr,
                std::mem::size_of::<libc::sockaddr_nl>() as libc::socklen_t,
            );
            if bound < 0 {
                libc::close(fd);
                return None;
            }

            Some(NetlinkSocket { fd })
        }
    }

    fn read(&self, buffer: &mut [u8]) -> Result<usize, ()> {
        // SAFETY: буфер принадлежит вызывающему и живёт дольше вызова.
        let read = unsafe {
            libc::recv(
                self.fd,
                buffer.as_mut_ptr() as *mut libc::c_void,
                buffer.len(),
                0,
            )
        };
        if read > 0 {
            Ok(read as usize)
        } else {
            Err(())
        }
    }
}

impl Drop for NetlinkSocket {
    fn drop(&mut self) {
        // SAFETY: дескриптор наш и закрывается ровно один раз.
        unsafe { libc::close(self.fd) };
    }
}
