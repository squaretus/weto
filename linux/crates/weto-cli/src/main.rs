//! Точка входа `weto` (cargo-бинарник `weto-cli`).

use weto_cli::commands::Io;
use weto_cli::context::Context;

fn main() {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    let ctx = Context::from_env();
    // Под root всё, что создаст процесс, — только для root: журналы, учёт,
    // замок. Читаемые без sudo настройки и статус получают `0644` явно.
    if ctx.identity.is_root {
        weto_cli::context::restrict_umask();
    }
    // Потоки не запираются на весь запуск: `run` пишет лог из потока охраны,
    // и запертый главным потоком stdout повесил бы его на первой же строке.
    let mut out = std::io::stdout();
    let mut err = std::io::stderr();
    let mut input = std::io::stdin().lock();
    let code = weto_cli::main_with(
        &arguments,
        &ctx,
        &mut Io {
            out: &mut out,
            err: &mut err,
            input: &mut input,
        },
    );
    std::process::exit(code);
}
