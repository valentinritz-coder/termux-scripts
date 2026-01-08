#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: watch_ui_dump.sh [-i SECONDS] [-o DIR] [--dry-run] [-h]

Continuously capture Android UI screenshots and UIAutomator XML dumps.

Options:
  -i SECONDS   Interval between captures (default: 2)
  -o DIR       Output directory (default: $HOME/storage/shared/cfl_watch/captures)
  --dry-run    Show commands without executing captures
  -h, --help   Show this help message

Example:
  ./watch_ui_dump.sh -i 1 -o /sdcard/cfl_watch/captures
USAGE
}

interval=2
outdir="${HOME}/storage/shared/cfl_watch/captures"
dry_run=false

while getopts ":i:o:h-:" opt; do
  case "$opt" in
    i)
      interval="$OPTARG"
      ;;
    o)
      outdir="$OPTARG"
      ;;
    h)
      usage
      exit 0
      ;;
    -)
      case "$OPTARG" in
        dry-run)
          dry_run=true
          ;;
        help)
          usage
          exit 0
          ;;
        *)
          echo "Unknown option --$OPTARG" >&2
          usage
          exit 1
          ;;
      esac
      ;;
    \?)
      echo "Unknown option -$OPTARG" >&2
      usage
      exit 1
      ;;
    :)
      echo "Option -$OPTARG requires an argument" >&2
      usage
      exit 1
      ;;
  esac
done

if ! command -v adb >/dev/null 2>&1; then
  echo "Error: adb is not available in PATH. Please install or configure adb." >&2
  exit 1
fi

png_dir="$outdir/png"
xml_dir="$outdir/xml"
index_file="$outdir/index.csv"

mkdir -p "$png_dir" "$xml_dir"

if [[ "$dry_run" == false && ! -f "$index_file" ]]; then
  echo "frame,timestamp,rc_png,rc_xml,notes" > "$index_file"
fi

remote_tmp_dir="/sdcard/cfl_watch_tmp"
if [[ "$dry_run" == false ]]; then
  adb shell mkdir -p "$remote_tmp_dir" >/dev/null 2>&1 || true
fi

epoch_ms() {
  local ms
  if ms=$(date +%s%3N 2>/dev/null) && [[ "$ms" =~ ^[0-9]+$ ]]; then
    echo "$ms"
  else
    echo $(( $(date +%s) * 1000 ))
  fi
}

frame_id() {
  local base
  local ms
  base=$(date +%Y-%m-%d_%H-%M-%S)
  ms=$(epoch_ms)
  printf "%s_%03d" "$base" "$((ms % 1000))"
}

log_line() {
  local frame="$1"
  local png_path="$2"
  local xml_path="$3"
  local rc_png="$4"
  local rc_xml="$5"
  local png_ms="$6"
  local xml_ms="$7"
  local total_ms="$8"
  local notes="$9"
  printf '[%s] png=%s (rc=%s,%sms) xml=%s (rc=%s,%sms) total=%sms %s\n' \
    "$frame" "$png_path" "$rc_png" "$png_ms" "$xml_path" "$rc_xml" "$xml_ms" "$total_ms" "$notes"
}

trap 'echo "Stopping..."; exit 0' INT TERM

while true; do
  frame=$(frame_id)
  timestamp=$(date +%Y-%m-%dT%H:%M:%S%z)
  png_path="$png_dir/$frame.png"
  xml_path="$xml_dir/$frame.xml"
  notes=""

  start_total=$(epoch_ms)

  if [[ "$dry_run" == true ]]; then
    echo "DRY-RUN: adb exec-out screencap -p > $png_path"
    echo "DRY-RUN: adb shell uiautomator dump --compressed $remote_tmp_dir/$frame.xml"
    echo "DRY-RUN: adb pull $remote_tmp_dir/$frame.xml $xml_path"
    echo "DRY-RUN: adb shell rm -f $remote_tmp_dir/$frame.xml"
    png_ms=0
    xml_ms=0
    total_ms=$(( $(epoch_ms) - start_total ))
    log_line "$frame" "$png_path" "$xml_path" 0 0 "$png_ms" "$xml_ms" "$total_ms" "dry-run"
    sleep "$interval"
    continue
  fi

  # PNG capture
  start_png=$(epoch_ms)
  rc_png=0
  set +e
  adb exec-out screencap -p > "$png_path"
  rc_png=$?
  set -e
  if [[ $rc_png -ne 0 ]]; then
    remote_png="$remote_tmp_dir/$frame.png"
    set +e
    adb shell screencap -p "$remote_png"
    rc_shell=$?
    if [[ $rc_shell -eq 0 ]]; then
      adb pull "$remote_png" "$png_path"
      rc_pull=$?
    else
      rc_pull=1
    fi
    adb shell rm -f "$remote_png" >/dev/null 2>&1
    set -e
    if [[ $rc_shell -ne 0 || $rc_pull -ne 0 ]]; then
      rc_png=1
      notes+="png_failed;"
    else
      rc_png=0
    fi
  fi
  png_ms=$(( $(epoch_ms) - start_png ))

  # XML capture
  start_xml=$(epoch_ms)
  rc_xml=0
  remote_xml="$remote_tmp_dir/$frame.xml"
  set +e
  adb shell uiautomator dump --compressed "$remote_xml"
  rc_dump=$?
  if [[ $rc_dump -eq 0 ]]; then
    adb pull "$remote_xml" "$xml_path"
    rc_pull_xml=$?
  else
    rc_pull_xml=1
  fi
  adb shell rm -f "$remote_xml" >/dev/null 2>&1
  set -e

  if [[ $rc_dump -ne 0 || $rc_pull_xml -ne 0 ]]; then
    rc_xml=1
    notes+="xml_failed;"
    printf '<error message="uiautomator dump failed"/>' > "$xml_path"
  fi
  xml_ms=$(( $(epoch_ms) - start_xml ))

  total_ms=$(( $(epoch_ms) - start_total ))

  echo "$frame,$timestamp,$rc_png,$rc_xml,${notes:-ok}" >> "$index_file"
  log_line "$frame" "$png_path" "$xml_path" "$rc_png" "$rc_xml" "$png_ms" "$xml_ms" "$total_ms" "${notes:-ok}"

  sleep "$interval"
done
