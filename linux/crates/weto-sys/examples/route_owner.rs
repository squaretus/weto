//! Печатает интерфейс, через который ядро выпускает трафик наружу.
//!
//! Нужен контракту `policy-routing-contract.sh`: тот сверяет ответ пробы
//! с `ip route get` в раскладке, которую делает `wg-quick`. Адрес назначения
//! передаётся аргументом — в контейнере DNS может не быть вовсе, а сверять
//! надо один и тот же адрес.

use weto_sys::network_snapshot::{KernelRouteProbe, RouteProbing};

fn main() {
    let probe = KernelRouteProbe::default();

    let route = match std::env::args().nth(1) {
        Some(destination) => probe.route_to(&destination),
        None => probe.outgoing_route(),
    };

    match route {
        Some(route) => println!("{}", route.interface),
        None => {
            eprintln!("маршрута наружу нет");
            std::process::exit(1);
        }
    }
}
