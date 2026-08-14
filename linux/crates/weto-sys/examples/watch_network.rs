//! Печатает `ready`, когда подписка открыта, и `event`, когда сеть изменилась.
//!
//! Две строки, а не одна: измерять реакцию имеет смысл от момента, когда
//! сеть дёрнули, а не от старта процесса. Иначе в «реакцию» попадёт время,
//! потраченное на запуск и открытие сокета.

use std::io::Write;
use std::time::Duration;

use weto_sys::network_events::{NetlinkEventSource, NetworkEventSourcing};

fn main() {
    let timeout: u64 = std::env::args()
        .nth(1)
        .and_then(|value| value.parse().ok())
        .unwrap_or(3000);

    let events = NetlinkEventSource.subscribe();

    println!("ready");
    std::io::stdout().flush().expect("stdout закрыт");

    match events.recv_timeout(Duration::from_millis(timeout)) {
        Ok(()) => println!("event"),
        Err(_) => {
            eprintln!("события не дождались за {timeout} мс");
            std::process::exit(1);
        }
    }
}
