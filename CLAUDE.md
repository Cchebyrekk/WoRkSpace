# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

# WoRkPlace

VR-приложение для работы с ПК на Windows: мониторы как виртуальные панели вокруг пользователя, управление руками (основной способ) или контроллерами. Работает на ПК через OpenXR (Quest 3S по Quest Link), не автономно в шлеме.

**Подробная история решений, проверок и причин ошибок по срезам — `docs/history.md`** (большой файл, целиком не читать: искать grep по имени класса, функции, настройки или по дате). Сюда — только то, что нужно в каждой сессии. Новые подробности записывать в `docs/history.md` в раздел своего среза, здесь — одной строкой, если это новое правило.

## Окружение

- Godot 4.7.2.stable.steam: `C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe`
- Windows 11 Pro, RTX 3060, среда OpenXR — Meta Quest Link. MSVC 14.51, Windows SDK 10.0.26100 (C++/WinRT), SCons через `py -3.12 -m pip install scons`.
- MCP-сервер `godot`: запуск проекта и чтение отладочного вывода.
- Для шлема (срез o, 26.10.2026): JDK 17 — `%LOCALAPPDATA%\Programs\jdk-17.0.21.0.2+1` (`JAVA_HOME`), Android SDK — `%LOCALAPPDATA%\Android\Sdk` (`ANDROID_HOME`; build-tools 35.0.1, android-35, cmake 3.10.2.4988404, NDK 28.1.13356709, adb в `platform-tools`), шаблоны экспорта и настройки редактора Godot из Steam — в самоописанном режиме рядом с exe (`…\Godot Engine\editor_data\`: `export_templates\4.7.2.stable`, `editor_settings-4.7.tres` с `export/android/java_sdk_path`, ключ отладки `keystores\debug.keystore`, пароль `android`); копия шаблонов в `%APPDATA%\Godot` ему не нужна. Приложение для шлема — отдельный проект `headset/` (основной его не видит: `.gdignore`); аддон `godot_openxr_vendors` 5.1.0-stable (`godotopenxrvendorsaddon.zip` с GitHub GodotVR) распаковать в `headset/addons/`, в git не хранится. Бэкап последней версии с Quest Link — тег `link-final` и ветка `link`.

## Команды

- Проверка скриптов без шлема: `& "<godot>" --headless --xr-mode off --path . --quit-after 5`. Осторожно: это настоящий запуск — он пишет `layout_backup.json` и может менять раскладку Windows; самоперезапуск после потери Link стартует уже **без** этих флагов и поднимает VR в шлеме.
- После нового скрипта с `class_name`: `& "<godot>" --headless --xr-mode off --path . --import` (падает, пока открыт редактор Godot).
- Тесты чистых классов: `& "<godot>" --headless --xr-mode off --path . -s tests/run_tests.gd` → «N проверок, M провалов». Новая группа — функция `_test_…` и её вызов в `_init`. `tests/*_probe.gd` — пробы с настоящим захватом/вводом/раскладкой, по одной через `-s`.
- Нативный модуль (из `native/`): `py -3.12 -m SCons platform=windows target=template_debug disable_exceptions=no -j8` → `bin/workplace_native…dll` (не в git). godot-cpp не в git: `git clone --depth 1 --branch master https://github.com/godotengine/godot-cpp native/godot-cpp` (коммит `b8530af`).
- Шлем (срез o): сборка — из `headset/`, с `JAVA_HOME` и `ANDROID_HOME`: `& "<godot>" --headless --xr-mode off --path . --export-debug "Quest" ../build/headset/workplace_headset.apk` (первый раз ещё `--install-android-build-template`; `build/` и `headset/android/` не в git). Отслеживание рук включается в настройках проекта (`openxr/extensions/hand_tracking`), не в пресете. Установка и запуск: `adb install -r …apk`, `adb shell am start -n com.workplace.headset/com.godot.game.GodotAppLauncher`. По Wi-Fi: по кабелю `adb tcpip 5555`, затем `adb connect <ip шлема>:5555` (адрес — `adb shell ip -f inet addr show wlan0`; 26.10.2026 был 192.168.1.71). Журнал приложения: `adb logcat -d -v brief -s godot` сразу после запуска (журнал Quest быстро прокручивается). Снятый шлем спит и запуск откладывает.
- Своя связь (срез o2): сервер ПК — `& "<godot>" --headless --xr-mode off --path . res://scenes/link_server.tscn` (`src/link_server.gd`; UDP 47801 — поиск, TCP 47802 — управление; первый запуск спрашивает брандмауэр). Протокол `src/link_protocol.gd` — его копия `headset/src/link_protocol.gd` должна совпадать байт в байт (проверяет тест). По кабелю: `adb reverse tcp:47802 tcp:47802` — шлем сам пробует 127.0.0.1. Проба без шлема: `-s tests/link_probe.gd` при запущенном сервере.
- Помощник VDD без изменений в системе: `<id> add|remove` в `<папка>\request.txt`, затем `tools\vdd_helper.ps1 -Dir <папка> -DryRun`.
- Запуск в шлеме: MCP `godot.run_project` или `& "<godot>" --path .` — предупреждать пользователя (картинка в шлеме переключится).
- Замороженные копии, не править: срез (a) — тег `slice-a`, `scenes/baseline/hands_scene.tscn`; срез (e) — тег `slice-e`, `scenes/baseline/slice_e.tscn`, скрипты `src/baseline/slice_e/` с классами `…E`. С основной версией у них общие нативный модуль, `tools/*.ps1` (менять только совместимо) и `user://settings.cfg`.

## Устройство

- `src/main.gd` (~8000 строк) — единственная сцена и дирижёр: OpenXR, руки и контроллеры (`_pointers[0|1]`, `mode`: «рука»/«контроллер»/«покой»), панели, курсор, панель настроек (вкладки `SETTINGS_TABS`, настройки — таблица `TUNABLES`), сохранение `user://settings.cfg` (`_load_settings`/`_save_settings`). Ручки, кнопки, меню укорачивают луч через `pointer.hit_distance`; указатель, который что-то держит, курсором не управляет.
- Остальные `src/*.gd` — чистые классы с тестами (жесты, позы, курсор, раскладки, стена/столб `WallLayout`, мир `WorldLayout`, меню, сеть мест `PlaceNetwork`, группы экранов `DesktopGroups`, редактор мира `WorldEdit`). Логику класть туда, в `main.gd` — связывание и узлы.
- Система меняется внешними процессами: `DisplayTopology` → `tools/display_topology.ps1` (CCD: раскладка, подключение экранов, режимы, окна; асинхронно, `busy`, по окончании `idle`); `VddControl` → задача `WoRkPlaceVddHelper` (`tools/vdd_helper.ps1` от администратора, файлы в `%ProgramData%\WoRkPlace\vdd`).
- Нативный модуль (`native/src`): `ScreenCapture`, `MouseInput` (ввод, запись сочетаний и текста с клавиатуры, связь с агентом), `GlobalHotkey`, `SecureDesktop`; агент SYSTEM `native/agent` → `bin/workplace_agent.exe`. Код Windows/WinRT — только в `win_backend.cpp` (C++20), заголовки Godot и Windows не смешивать.
- Git: после принятого среза — коммит и тег `slice-<буква>` (есть `slice-a`, `e`–`l`, `n1`, `n2`, `o1`, `o2`); на GitHub (`origin`, `Cchebyrekk/WoRkSpace`) — только по просьбе. README (для людей, по-русски) обновлять при закрытии среза.

## Журналы — читать самому после каждой проверки в шлеме

- Godot: `%APPDATA%\Godot\app_userdata\WoRkPlace\logs\godot.log` (последний запуск; `godot<дата>.log` — предыдущие, в имени время конца). Мои запуски без шлема тоже пишут сюда — искать запуск пользователя по строкам `[world]`/`[gesture]`.
- Топология: `%LOCALAPPDATA%\WoRkPlace\topology.log` (без дат в строках — только время; большой, читать хвост и grep по действиям `Arrange`/`SetMode`/`save`), `detached.json`.
- Помощник VDD: `%ProgramData%\WoRkPlace\vdd-log\helper.log`, ответ — `response.txt`.
- Выводы журналов в чат сокращать (`grep`, `tail`, `cut -c1-200`): они быстро съедают контекст.

## Правила, которые нельзя нарушать

- Захват: WGC, кадры на GPU (D3D11 → общая текстура → D3D12 Godot); рендерер D3D12 (Mobile) не менять. **Текстуру захвата не класть на 3D-материал** (теряется устройство D3D12, `0x887A0005`) — только через composition layer или свой SubViewport (миниатюры, выпуклые экраны). Вьюпорт панели, привязанный к слою, на меши не годится (чёрный).
- Панели — OpenXR composition layers с hole punch; картинка слоя ≤ 4096 по стороне (`MAX_LAYER_SIDE`, иначе Link не даёт swapchain). Цилиндр Link рисует только изнутри.
- Ошибка скрипта посреди кадра в VR = зависание (OpenXR теряет порядок кадров): индексы и запомненные ссылки проверять перед использованием.
- Мониторы идентифицировать по ключу пути устройства (`ScreenPanel.key_of`, `MTT1337#…`), **не** по `\\.\DISPLAYnn`.
- Раскладка — CCD (`QueryDisplayConfig`/`SetDisplayConfig`), режимы — тоже CCD (`Ccd.SetMode`); `ChangeDisplaySettingsEx` ломал соседние экраны. После изменений скрипт возвращает окна на их мониторы (слежение до 10 с). Несколько режимов — одним вызовом `setmodes`.
- Ввод — `SendInput` в настоящих пикселях (`PER_MONITOR_AWARE_V2`); свои нажатия помечены `INJECTED_BY_WORKPLACE`. `DisplayServer.mouse_get_position()` не годится.
- Выход: «Выход» в VR (1 с), `Esc`, аварийная `Ctrl+Alt+Shift+F12` (она же возвращает исходную раскладку).
- Потеря сессии Link → самоперезапуск (`_restart_app`, `WORKPLACE_XR_RETRY`, до 60 попыток; `SessionLossLogger` ловит и молчаливую потерю, и `0x887A0005`).
- `.ps1` — только ASCII (PowerShell 5.1 читает без BOM как ANSI); C# внутри — C# 5.
- Кнопки в VR срабатывают по удержанию, начатому на кнопке. Все пороги — на панели настроек, хранятся в `settings.cfg`.
- Суставы руки, синтезированные из контроллера, рукой не считаются; контроллер — только профиль не `hand_interaction`.

## Виртуальные дисплеи (VDD) — осторожно

- MTT Virtual Display Driver (`Root\MttVDD`), конфиг `C:\VirtualDisplayDriver\vdd_settings.xml` (список разрешений общий для всех экземпляров; **первое в списке Windows ставит экранам при сбросе** — первым держать 1920×1080, `VddConfig.ordered`). Пределы разрешений — `VddConfig` (ширина ≤ 15360, высота ≤ 8640, пикселей ≤ 15360×1080, меньшая сторона ≥ 360); недопустимое не писать — однажды драйвер не поднял ни одного экрана, однажды упала Windows.
- Экземпляров до 16 (`$MaxScreens` в помощнике, `DRIVER_MAX_INSTANCES` в приложении; до 24.10.2026 было 8; больше видеопамяти — увеличивать по одному и проверять); число меняется только «Применить» на вкладке «Драйвер» (помощник `apply N`, перезапуск драйвера, Link переподключится; раскладка и окна возвращаются после). **`count` не менять**; `ROOT\DISPLAY\0000` (Meta) не трогать.
- Пользователь видит ПК только через эти экраны: никогда не доводить число экранов до нуля, менять по одному и проверять; UAC — один раз заранее. После правки помощника — переустановить `tools/install_vdd_helper.ps1` от администратора; агента — `tools/install_agent.ps1`.

## Как вести работу

- Вертикальные срезы: (a) руки и контроллеры; (b) один экран; (c) курсор; (d) все мониторы; (e) жесты; (f) перенос панелей ↔ раскладка Windows; (g) VDD; (h) агент SYSTEM; (i) основа мира; (j) шары, меню; (k) стена; (l) столб; (m) сеть мест; (n1) группы экранов; (n2) редактор мира (режим, полочка, перенос заготовок по сетке, мониторы между заготовками, кольцо на карте, имена с клавиатуры, миры) — приняты (m и n1 — тег `slice-n1`, n2 — `slice-n2`).
- После каждого среза сказать пользователю, что проверить в шлеме, и ждать ответа; коммит — после подтверждения.
- После каждого изменения отчитываться: в чём была ошибка, что затронуто и как исправлено, что проверить.
- Не делать сейчас: виртуальная клавиатура, захват окон, passthrough, автономная сборка, звук. Отложено пользователем: виртуальные рабочие столы, самонастройка жестов «относительно», расстановка экранов на разном расстоянии.
