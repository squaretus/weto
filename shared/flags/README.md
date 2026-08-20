# Флаги стран

Набор `circle-flags` (MIT, см. `LICENSE.md`), только двухбуквенные коды
ISO 3166-1 alpha-2 — именно их возвращают гео-сервисы.

Лежит здесь, а не тянется из сети: `cdn.jsdelivr.net` в России блокируется,
а приложение показывает флаг ровно тогда, когда пользователь под VPN и без
него до CDN не дойдёт. Плюс первый флаг больше не появляется с задержкой
в сетевой запрос.

Обновление набора:

```bash
curl -sL -o /tmp/circle-flags.tar.gz \
    https://codeload.github.com/HatScripts/circle-flags/tar.gz/refs/heads/gh-pages
mkdir -p /tmp/circle-flags && tar xzf /tmp/circle-flags.tar.gz \
    -C /tmp/circle-flags --strip-components=1
cd /tmp/circle-flags/flags && for f in ??.svg; do cp -L "$f" <репозиторий>/shared/flags/; done
shared/tools/sync-flags.sh
```
