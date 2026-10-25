# FamilyGram iOS

Неофициальный клиент Telegram для iPhone/iPad. Основа: официальный Telegram iOS **13.1.1**, iOS **15.0+**. Это отдельный iOS-проект: APK из Android здесь не используется.

**Статус:** базовый IPA установлен пользователем на iPhone. Перенос функций Android опубликован в ветке `feature/family-ios`, [PR #1](https://github.com/Zaharka0/FamilyGram-iOS/pull/1). Проверки протокола и состояний карточек Android/Swift, Python SDK и применения патчей прошли; полная нативная сборка переноса и проверки на двух устройствах ещё не завершены. Список возможностей, ограничения iOS и план проверки: [PORT-STATUS.md](PORT-STATUS.md).

## Что добавлено

- Название FamilyGram на домашнем экране, в том числе при русской локализации.
- Основная иконка «Сердце FamilyGram» и пять фотоиконок, доступных без Premium через **Настройки → Оформление → Иконка приложения**. Превью и системная иконка используют одно изображение.
- Воспроизводимая подготовка официального исходного кода по точному commit SHA из `upstream.json`; все изменения публикуются в `scripts/patch_source.py` и `scripts/patch_rules.py`.
- Отдельный режим сборки для последующей подписи AltStore, без сертификатов Apple и Watch-приложения. В ветке переноса добавлено отдельное расширение WidgetKit пары. Его работа требует корректной подписи App Group через AltStore. Уведомления, Siri, iCloud и расширение «Поделиться» в этом варианте не гарантируются.
- Проверка, что IPA содержит arm64-приложение для настоящего iPhone, правильное название, bundle ID и пять альтернативных иконок.
- SHA-256 и JSON с происхождением сборки рядом с IPA.

## Сборка через GitHub — Mac у себя не нужен

1. В **Settings → Secrets and variables → Actions → New repository secret** добавьте:
   - `API_ID` — свой Telegram API ID;
   - `API_HASH` — свой Telegram API hash.
   Получить их можно на https://my.telegram.org/apps. Если используете собственные значения Android-проекта, добавьте их и в этот репозиторий: секреты между репозиториями автоматически не переносятся. Не присылайте их в чат.
2. Откройте **Actions → iOS IPA (AltStore) → Run workflow → main**. Для теста переноса выберите ветку **feature/family-ios**.
3. Оставьте `org.familygram.ios` как bundle ID. Сохраняйте его при будущих обновлениях.
4. После **успешной** сборки скачайте артефакт **FamilyGram-iOS-AltStore**, распакуйте ZIP и возьмите `FamilyGram.ipa`.
5. Откройте **AltStore Classic → My Apps → +**, выберите IPA. AltStore подпишет его вашим Apple ID. Apple ID и пароль не нужны GitHub Actions.

Сборка использует `xcode-27` и Xcode **27.1** на macOS **27**, как закреплено в официальных исходниках. Этот образ GitHub находится в public preview; если он недоступен вашему аккаунту или сборка упирается в память/диск/лимит времени, потребуется подходящий macOS runner. Подмена версии Xcode флагом override не используется. Полная первая сборка Telegram тяжёлая; workflow ограничен шестью часами.

С обычным бесплатным Apple ID подпись AltStore Classic действует **7 дней**, затем её нужно обновить; AltStore может обновлять её через AltServer. Учитывайте ограничения количества приложений/App IDs. AltStore PAL не является заменой установке произвольного IPA через Classic.

**Важно для первого теста:** подпись, доступ к App Group/Keychain, вход в аккаунт, смену всех иконок и сохранение сессии после обновления подписи нужно проверить на реальном iPhone. Структурная проверка ZIP этого не доказывает. Исходный код Telegram использует общую группу приложения для хранения данных; при упаковке соответствующие entitlements сохраняются в ad-hoc подписи для обработки AltStore. Если AltStore сообщает о недоступной возможности, нельзя просто удалить App Group и считать сборку рабочей.

## Локальная сборка на Mac

```sh
python3 -m pip install -r requirements.txt
export DEVELOPER_DIR=/Applications/Xcode_27.1.app/Contents/Developer
# API_ID и API_HASH задайте в окружении локально.
python3 scripts/configure.py
python3 scripts/preflight.py
python3 scripts/checkout.py
python3 scripts/patch_source.py
python3 scripts/patch_rules.py
python3 scripts/icons.py
python3 scripts/build.py --build-number 1
```

Результат: `dist/FamilyGram.ipa`, `.ipa.sha256` и `.json`. Сборка ad-hoc подписана только для сохранения entitlements; установить её напрямую как подписанное Apple приложение нельзя — нужна повторная подпись AltStore. Публикация IPA в GitHub Releases включается отдельным флажком `publish_release` при ручной сборке `main`, только после успешной компиляции. Из ветки переноса публичный релиз не создаётся. Тег содержит версию и номер сборки; именно эти релизы проверяет обновление внутри приложения.

Для повторной сборки исходников используйте новую папку `source`, сохранив собственные изменения заранее. Скрипт не делает `reset --hard`, не заменяет чужой HEAD и не накладывает патч второй раз. Приватный конфиг, IPA, исходники и ключи исключены из Git. Удаление конфигурации после сборки не означает сокрытие API ID/hash внутри клиентского приложения — эти параметры Telegram нужны клиенту.

## Проверки и устройство проекта

```sh
python3 -m unittest discover -s tests -v
```

`Source and packaging checks` дополнительно получает закреплённые файлы Telegram, проверяет применимость патча и размеры/ресурсы шести иконок. Это **не компиляция iOS**. `iOS IPA (AltStore)` вручную, а в ветке переноса также при push, запускает полный arm64 release build и только после успеха загружает IPA.

Исходники Telegram скачиваются при подготовке проекта, а не копируются многогигабайтным деревом в этот репозиторий. `upstream.json` фиксирует источник и инструменты; `scripts/patch_source.py` и `scripts/patch_rules.py` — полный опубликованный набор изменений. `icons.json` фиксирует существующие изображения из публичного FamilyGram-Android по commit SHA и SHA-256; новые личные оригиналы фотографий здесь не публикуются. Фотоиллюстрации ранее подготовлены из пяти фотографий пользователя, шестая иконка создана специально для FamilyGram. При распространении бинарной сборки сохраняйте соответствующий исходный commit и опубликованные изменения.

Новые скрипты и изменения распространяются по GPL-2.0-or-later; Telegram и его зависимости сохраняют собственные лицензии. FamilyGram не является официальным приложением Telegram.

## Проверка переноса

Общие карточки используют тот же бинарный протокол `fg1`, что Android. CI генерирует журнал настоящим Android reducer и сравнивает Swift-состояния при прямом и обратном порядке сообщений и разных локальных ID. Это дополняет 18 байтовых wire vectors и проверки SDK.

Нативные экраны, WidgetKit, проигрывание, AltStore и синхронизация двух телефонов требуют отдельных проверок на устройствах. Доступность кода не означает завершённую ручную проверку. Инструкции: [PORT-STATUS.md](PORT-STATUS.md). Python SDK 1 общий, но Android Java/Chaquopy/Xposed API на iOS отсутствуют.

Официальные источники: [Telegram iOS](https://github.com/TelegramMessenger/Telegram-iOS), [AltStore Classic](https://faq.altstore.io/altstore-classic/your-altstore), [GitHub Xcode 27 runner](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md).

## Исправление первой сборки

Первый запуск IPA останавливался на анализе Bazel: `Building for device, but no provisioning_profile attribute was set`. `disable_legacy_signing` отключал подпись, но правило `ios_application` отдельно требовало встраивания профиля. `patch_rules.py` пропускает этот шаг только при одновременных `familygram.altstore_unsigned`, `disable_legacy_signing` и отсутствии профиля. Обычные device builds по-прежнему требуют профиль; существующие профили сохраняются. Для исправления нужен новый **Run workflow** из текущего `main`: **Re-run jobs** старого запуска использует старый commit и не получит исправление.

## ZIP с .app для Appetize / iOS Simulator

Для облачного симулятора используйте **Actions → iOS Simulator (.app ZIP) → Run workflow → main**. Используются те же секреты `API_ID` и `API_HASH`. Этот workflow компилирует `release_sim_arm64` для iOS Simulator, а не переупаковывает device IPA.

После успешной сборки:

1. Скачайте артефакт **FamilyGram-iOS-Simulator-arm64**.
2. Распакуйте внешний ZIP, скачанный с GitHub Actions.
3. Найдите внутри **`FamilyGram-Simulator-arm64.zip`** и загрузите **его** в форму Appetize. Внутри него `FamilyGram.app` расположен прямо в корне, без папки `Payload`.
4. Выберите среду **ARM64 iOS Simulator**, с iOS не ниже минимальной версии приложения. AltStore и Apple ID для этой сборки не нужны.

Локально на подходящем Mac, после обычной подготовки исходников:

```sh
python3 scripts/build.py --target simulator --build-number 1
```

Рядом с архивом создаются SHA-256 и JSON с данными сборки. Проверяется `iPhoneSimulator` в Info.plist и платформа **7 / IOSSIMULATOR** в Mach-O: одной архитектуры arm64 недостаточно. Device IPA по-прежнему проверяется как платформа **2 / IOS**. Эти форматы не взаимозаменяемы. Проверки упаковки не подтверждают успешный запуск/вход в Telegram в облачном сервисе; это нужно проверить после первой полной сборки.
