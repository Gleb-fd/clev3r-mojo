#!/usr/bin/env bash
# Установка Clev3r Mojo: сборка компилятора `tools/bp` из исходников.
#
#   ./install.sh              собрать компилятор и прогнать смоук-тест
#   ./install.sh --with-zed   дополнительно поставить расширение Basic Plus в Zed
#
# Зависимости: git, python3, curl (для установки uv, если её нет).
# Mojo ставится сам через uv при первом запуске (`uv sync`).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WITH_ZED=0

for arg in "$@"; do
    case "$arg" in
        --with-zed) WITH_ZED=1 ;;
        -h|--help)
            sed -n '2,8p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "неизвестный аргумент: $arg (см. --help)"; exit 2 ;;
    esac
done

cd "$REPO_DIR"

echo "== проверка зависимостей =="
missing=0
for tool in git python3 curl; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "   не найдено: $tool"
        missing=1
    fi
done
if [[ $missing -ne 0 ]]; then
    echo "Поставь недостающие пакеты пакетным менеджером дистрибутива и запусти снова."
    exit 1
fi

if ! command -v uv >/dev/null 2>&1; then
    echo "== ставлю uv (менеджер окружений Python/Mojo) =="
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
fi

echo "== окружение Mojo (uv sync) =="
uv sync

echo "== сборка tools/bp =="
uv run mojo build src/bp/main.mojo -o tools/bp

echo "== смоук-тест =="
./tools/bp check tests/corpus/Functions/Test1.bp

if [[ $WITH_ZED -eq 1 ]]; then
    echo "== расширение Zed =="
    bash tools/install_zed_extension.sh
else
    cat <<'EOF'

Расширение Zed не ставилось. Чтобы поставить:
    ./install.sh --with-zed
или вручную: Zed -> Extensions -> Install Dev Extension -> каталог zed-extension/
(второй путь требует rust с таргетом wasm32-wasip2).
EOF
fi

cat <<'EOF'

Готово. Быстрая проверка:
    tools/bp compile tests/corpus/Functions/Test1.bp

Заливка на кирпич:
    tools/bp flash prog.bp                  # USB (кабель)
    tools/bp flash prog.bp wifi:192.168.1.x # Wi-Fi
    tools/bp flash prog.bp bt:00:16:53:XX:XX:XX  # Bluetooth
EOF
