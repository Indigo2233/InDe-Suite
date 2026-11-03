#!/bin/bash
ROOT="$(cd "$(dirname "$0")" && pwd)"
/bin/bash "$ROOT/setup-macos.sh" "$@"
status=$?
echo
if [[ $status -ne 0 ]]; then echo "安装未完成，请查看上方信息。"; fi
if [[ -t 0 ]]; then read -r -p '按回车关闭此窗口。'; fi
exit "$status"
