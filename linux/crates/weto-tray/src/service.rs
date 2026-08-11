//! Запуск иконки и синхронный доступ к ней.
//!
//! `ksni` асинхронный, а всё остальное приложение — нет: у GTK свой цикл
//! событий, у охраны свой поток. Рантайм заводится ровно здесь, на одном
//! потоке, и наружу торчит обычный канал. Так tokio не расползается по крейтам,
//! а инвариант `weto-core` остаётся машинно проверяемым.

use std::sync::mpsc::Sender;

use tokio::sync::mpsc::UnboundedSender;
use weto_core::presentation::ShieldState;

use crate::{TrayEvent, WetoTray};

/// Ручка для обновления иконки. Отправка синхронная — вызывается из главного
/// цикла GTK.
pub struct TrayHandle {
    updates: UnboundedSender<(ShieldState, String)>,
}

impl TrayHandle {
    pub fn set_status(&self, state: ShieldState, title: &str) {
        // Приёмник исчезает только вместе с потоком трея; молчание здесь
        // означает, что показывать уже нечего.
        let _ = self.updates.send((state, title.to_string()));
    }
}

/// Поднимает иконку в отдельном потоке.
///
/// `None` означает, что трея в системе нет — ванильный GNOME без расширений,
/// например. Это свойство окружения, а не ошибка: у приложения есть второй
/// вход через ярлык и повторный запуск.
pub fn spawn(events: Sender<TrayEvent>) -> Option<TrayHandle> {
    let (updates, mut inbox) = tokio::sync::mpsc::unbounded_channel::<(ShieldState, String)>();
    let (ready, ready_rx) = std::sync::mpsc::channel();

    std::thread::Builder::new()
        .name("weto-tray".to_string())
        .spawn(move || {
            let runtime = match tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
            {
                Ok(runtime) => runtime,
                Err(_) => {
                    let _ = ready.send(false);
                    return;
                }
            };

            runtime.block_on(async move {
                use ksni::TrayMethods;

                let handle = match WetoTray::new(events).spawn().await {
                    Ok(handle) => handle,
                    Err(error) => {
                        eprintln!("weto: иконка в трее не поднялась: {error}");
                        let _ = ready.send(false);
                        return;
                    }
                };
                let _ = ready.send(true);

                while let Some((state, title)) = inbox.recv().await {
                    handle
                        .update(move |tray: &mut WetoTray| tray.set_status(state, &title))
                        .await;
                }
            });
        })
        .ok()?;

    // Ждём ответа от потока: сообщать «трея нет» надо один раз и сразу,
    // а не выяснять это по молчанию иконки.
    match ready_rx.recv_timeout(std::time::Duration::from_secs(5)) {
        Ok(true) => Some(TrayHandle { updates }),
        _ => None,
    }
}
