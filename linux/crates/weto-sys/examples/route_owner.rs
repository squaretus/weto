//! Печатает интерфейс, через который ядро выпускает трафик наружу.
//!
//! Нужен контракту `policy-routing-contract.sh`: тот сверяет ответ пробы
//! с `ip route get` в раскладке, которую делает `wg-quick`.

use weto_sys::network_snapshot::{KernelRouteProbe, RouteProbing};

fn main() {
    match KernelRouteProbe.outgoing_interface() {
        Some(name) => println!("{name}"),
        None => {
            eprintln!("маршрута наружу нет");
            std::process::exit(1);
        }
    }
}
