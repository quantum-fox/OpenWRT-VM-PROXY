# Образ роутера (`pw2-router.ova`)

Сюда кладётся файл `pw2-router.ova` (вариант B). Если вы скачали продукт из репозитория GitHub, **самого файла здесь нет**: образ (около 36 МБ) выкладывается не в код, а в раздел **Releases** репозитория (страница «Releases», блок «Assets»).
1. Скачайте с той же страницы релиза два файла: `pw2-router.ova` и `pw2-router.ova.sha256`.
2. Положите их в эту папку (`B-ready-image\image`) и выполните `.\vm-import.ps1` из `tools\windows` — он найдёт образ сам и проверит контрольную сумму. Образ можно держать и в другом месте: `.\vm-import.ps1 -Ova D:\путь\pw2-router.ova` (файл `.sha256` должен лежать рядом).
Версия образа указана на странице релиза; после импорта выполните обновление ([../../docs/update.md](../../docs/update.md)): оно доведёт роутер до последней версии скриптов.

---

# Router image (`pw2-router.ova`)

Place `pw2-router.ova` here (variant B). If you downloaded the project from GitHub, **the file is not in the repository**: the ~36 MB image is published under the repository's **Releases** page ("Assets").
1. Download `pw2-router.ova` and `pw2-router.ova.sha256` from the release page.
2. Put both files into this folder (`B-ready-image\image`) and run `.\vm-import.ps1` from `tools\windows` - it finds the image and verifies the checksum. Another location works too: `.\vm-import.ps1 -Ova D:\path\pw2-router.ova` (keep the `.sha256` file next to it).
The image version is shown on the release page; after importing, run the update ([../../docs/update.md](../../docs/update.md)) to bring the router to the latest script version.
