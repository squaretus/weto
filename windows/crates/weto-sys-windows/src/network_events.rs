//! События сети Windows — замена netlink.
//!
//! Три подписки IP Helper: интерфейсы (появление, исчезновение, смена
//! состояния), одноадресные адреса и маршруты обеих версий IP. Обратный вызов
//! приходит на потоке пула и лишь кладёт сигнал в канал: что изменилось, охране
//! неважно — она перечитывает снимок сама.
//!
//! Подписка живёт до конца процесса: трейт отписки не знает, а охрана
//! подписывается один раз на старте. Контекст обратного вызова поэтому
//! отдаётся ядру навсегда.

use std::ffi::c_void;
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::Mutex;

use windows_sys::Win32::Foundation::HANDLE;
use windows_sys::Win32::NetworkManagement::IpHelper::{
    NotifyIpInterfaceChange, NotifyRouteChange2, NotifyUnicastIpAddressChange, MIB_IPFORWARD_ROW2,
    MIB_IPINTERFACE_ROW, MIB_NOTIFICATION_TYPE, MIB_UNICASTIPADDRESS_ROW,
};
use windows_sys::Win32::Networking::WinSock::AF_UNSPEC;

use weto_sys::network_events::NetworkEventSourcing;

#[derive(Debug, Default, Clone, Copy)]
pub struct IpHelperEventSource;

impl NetworkEventSourcing for IpHelperEventSource {
    fn subscribe(&self) -> Receiver<()> {
        let (sender, receiver) = mpsc::channel();
        // Обратные вызовы приходят на разных потоках пула одновременно,
        // а `Sender` по ссылке между потоками не делится.
        let context: &'static Mutex<Sender<()>> = Box::leak(Box::new(Mutex::new(sender)));
        let context = (context as *const Mutex<Sender<()>>).cast::<c_void>();

        let mut interface: HANDLE = std::ptr::null_mut();
        let mut address: HANDLE = std::ptr::null_mut();
        let mut route: HANDLE = std::ptr::null_mut();
        // Отказ подписки — не авария: охрана перечитывает снимок каждый такт
        // и без событий, они лишь сокращают реакцию на смену сети.
        // SAFETY: контекст живёт до конца процесса (`Box::leak`), обратные вызовы
        // только читают его; handle подписок не закрываются намеренно.
        unsafe {
            NotifyIpInterfaceChange(
                AF_UNSPEC,
                Some(on_interface),
                context,
                false,
                &mut interface,
            );
            NotifyUnicastIpAddressChange(AF_UNSPEC, Some(on_address), context, false, &mut address);
            NotifyRouteChange2(AF_UNSPEC, Some(on_route), context, false, &mut route);
        }
        receiver
    }
}

fn signal(context: *const c_void) {
    // SAFETY: контекст — `Mutex<Sender<()>>`, отданный ядру навсегда в `subscribe`.
    let sender = unsafe { &*context.cast::<Mutex<Sender<()>>>() };
    if let Ok(sender) = sender.lock() {
        // Получатель ушёл — охрана завершается; сигналу некуда идти, и это не ошибка.
        let _ = sender.send(());
    }
}

unsafe extern "system" fn on_interface(
    context: *const c_void,
    _row: *const MIB_IPINTERFACE_ROW,
    _kind: MIB_NOTIFICATION_TYPE,
) {
    signal(context);
}

unsafe extern "system" fn on_address(
    context: *const c_void,
    _row: *const MIB_UNICASTIPADDRESS_ROW,
    _kind: MIB_NOTIFICATION_TYPE,
) {
    signal(context);
}

unsafe extern "system" fn on_route(
    context: *const c_void,
    _row: *const MIB_IPFORWARD_ROW2,
    _kind: MIB_NOTIFICATION_TYPE,
) {
    signal(context);
}
