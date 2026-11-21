# Privacy policy / Политика конфиденциальности

The same text is inside the app: Settings → Privacy policy.

IP Browser — Privacy Policy

IP Browser has no accounts, no analytics, no advertising and no servers of its developer in the path of your browsing.

What the app stores, on your device only: the servers you add (address, keys), each profile's website data (cookies, storage), history, favorites, tabs, the connection log and settings. Keys are kept in the iOS Keychain of this device only. Website data, history, favorites, tabs and the connection log are excluded from iCloud and computer backups; settings (search engine, switches) may be backed up by iOS.

Where your traffic goes: websites, their name lookups and downloads go only to the server you configured — your own server, or a server whose owner gave you a key. That server's owner can see which websites you connect to (not the content of HTTPS pages). The developer of IP Browser receives nothing.

When you install a server: the app connects to the address you entered over SSH, uses your password once to install the software and adds its own key for managing that server later. The password is not stored.

What the app checks: after connecting, after every network change, every 10 minutes and when one connection kind stops answering, the app asks a public address service (checkip.amazonaws.com, api.ipify.org) through your server — once through each connection kind of that server — which address websites see. Apart from these and the time-zone services below, the app contacts no service in the background.

Time zone: the first time a server's address is seen, the app asks a public service (ipapi.co, or ipwho.is, or api.ip.sb) through your server which country and time zone that address is in, and keeps the answer on the phone (the country names the profile). Websites then see the server's time zone instead of the phone's (Settings → Server's time zone turns this off). The phone's own clock does not change. Websites do not get your location: the app never asks iOS for it.

Not routed through your server: system services of iOS itself (Apple software updates, certificate status checks, Apple's content lists) use your normal network.

Camera: used only to scan an access QR code, the image is not saved. Photos: an image you attach on a website — from Photos or from Files — is re-encoded without location and camera data; other files go as they are.

Delete everything: delete the app, or remove a server in Servers and clear website data in Settings.

---

IP Browser — политика конфиденциальности

У IP Browser нет аккаунтов, аналитики, рекламы и серверов разработчика на пути ваших страниц.

Что хранит приложение, только на вашем устройстве: добавленные серверы (адрес, ключи), данные сайтов каждого профиля (cookies, хранилище), историю, избранное, вкладки, журнал подключения и настройки. Ключи лежат в Связке ключей iOS только этого устройства. Данные сайтов, история, избранное, вкладки и журнал исключены из резервных копий iCloud и компьютера; настройки (поисковик, переключатели) iOS может сохранить в копии.

Куда идёт трафик: сайты, поиск их адресов и загрузки идут только на настроенный вами сервер — ваш собственный или сервер, владелец которого дал вам ключ. Владелец сервера может видеть, к каким сайтам вы подключаетесь (не содержимое HTTPS-страниц). Разработчик IP Browser не получает ничего.

Когда вы ставите сервер: приложение подключается по SSH к указанному адресу, один раз использует пароль для установки и добавляет свой ключ, чтобы потом управлять сервером. Пароль не сохраняется.

Что проверяет приложение: после подключения, после каждой смены сети, раз в 10 минут и когда один из видов подключения перестаёт отвечать, оно через ваш сервер — по разу через каждый вид подключения этого сервера — спрашивает у публичной службы адреса (checkip.amazonaws.com, api.ipify.org), какой адрес видят сайты. Кроме них и служб часового пояса ниже, приложение в фоне ни к кому не обращается.

Часовой пояс: когда адрес сервера встречается впервые, приложение через ваш сервер спрашивает у публичной службы (ipapi.co, ipwho.is или api.ip.sb), в какой стране и каком часовом поясе этот адрес, и хранит ответ на телефоне (страна — для названия профиля). Сайты видят пояс сервера, а не телефона (выключается в «Настройки → Время как у сервера»). Часы самого телефона не меняются. Геопозицию сайты не получают: приложение никогда не спрашивает её у iOS.

Не через ваш сервер: системные службы самой iOS (обновления Apple, проверка статуса сертификатов, списки Apple) ходят обычной сетью.

Камера — только чтобы считать QR-код ключа, снимок не сохраняется. Изображение, которое вы прикрепляете на сайте — из «Фото» или из «Файлов», — пересохраняется без геопозиции и данных камеры; другие файлы уходят как есть.

Удалить всё: удалите приложение или удалите сервер в «Серверах» и очистите данные сайтов в «Настройках».
