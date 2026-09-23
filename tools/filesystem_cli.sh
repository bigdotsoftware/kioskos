#!/bin/bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

usage() {
	cat <<'EOF'
Usage:
	filesystem_cli.sh [options] <command> [args...]

Options:
	-u, --url URL        Kiosk API base URL (default: http://kiosk.local)
	-p, --pin PIN        Login PIN (default: 1111)
	--path PATH          Remote base path for relative paths (default: /)
	-h, --help           Show help

Commands:
	ls [PATH]                 List files and directories
	info PATH                 Show file or directory info
	mkdir PATH                Create a directory
	rmdir PATH                Remove a directory
	rm PATH                   Remove a file
	mv SRC DST                Move or rename a file or directory
	rename SRC DST            Alias for mv
	upload LOCAL [REMOTE_DIR] Upload a local file into REMOTE_DIR
	download REMOTE [LOCAL]   Download a remote file to LOCAL path

Examples:
	filesystem_cli.sh ls documents/2026
	filesystem_cli.sh mkdir documents/2026/demo
	filesystem_cli.sh mv documents/2026/a.txt documents/2026/archive/a.txt
	filesystem_cli.sh upload ./hello.html documents/2026
	filesystem_cli.sh download documents/2026/hello.html /tmp/hello.html
EOF
}

die() {
	echo "Error: $*" >&2
	exit 1
}

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

normalize_remote_path() {
	local input="${1:-}"

	if [[ -z "$input" || "$input" == "/" ]]; then
		printf '%s' "$REMOTE_PATH_PREFIX"
		return
	fi

	if [[ "$input" == /* ]]; then
		printf '%s' "${input#/}"
	elif [[ -n "$REMOTE_PATH_PREFIX" ]]; then
		printf '%s/%s' "$REMOTE_PATH_PREFIX" "$input"
	else
		printf '%s' "$input"
	fi
}

auth_login() {
	local login_response login_status body token

	login_response="$(curl -sS -w '\n%{http_code}' -X POST "$API_URL/api/login" \
		-H "Content-Type: application/json" \
		-d "{\"pin\":\"$PIN\"}")"
	login_status="${login_response##*$'\n'}"
	body="${login_response%$'\n'*}"

	if [[ "$login_status" != 2* ]]; then
		echo "$body" >&2
		die "Login failed with HTTP $login_status"
	fi

	token="$(printf '%s' "$body" | jq -r '.token')"

	if [[ -z "$token" || "$token" == "null" ]]; then
		echo "$body" >&2
		die "Login failed"
	fi

	TOKEN="$token"
}

api_json() {
	local method="$1"
	local endpoint="$2"
	local data="${3:-}"

	if [[ -n "$data" ]]; then
		curl -sS -X "$method" "$API_URL$endpoint" \
			-H "Authorization: Bearer $TOKEN" \
			-H "Content-Type: application/json" \
			-d "$data"
	else
		curl -sS -X "$method" "$API_URL$endpoint" \
			-H "Authorization: Bearer $TOKEN"
	fi
}

api_get() {
	local endpoint="$1"
	shift

	curl -sS -G "$API_URL$endpoint" \
		-H "Authorization: Bearer $TOKEN" \
		"$@"
}

list_remote() {
	local remote_path="$1"
	api_get "/api/files/list" \
		--data-urlencode "path=$remote_path" \
		--data-urlencode "page=1" \
		--data-urlencode "per_page=1000" \
		--data-urlencode "sort=name" \
		--data-urlencode "order=asc"
}

info_remote() {
	local remote_path="$1"
	api_get "/api/files/info" --data-urlencode "path=$remote_path"
}

mkdir_remote() {
	local remote_path="$1"
	api_json POST "/api/files/dir" "{\"path\":\"$remote_path\"}"
}

rmdir_remote() {
	local remote_path="$1"
	api_json DELETE "/api/files/dir" "{\"path\":\"$remote_path\"}"
}

rm_remote() {
	local remote_path="$1"
	api_json DELETE "/api/files/file" "{\"path\":\"$remote_path\"}"
}

mv_remote() {
	local src="$1"
	local dst="$2"
	api_json POST "/api/files/move" "{\"src\":\"$src\",\"dst\":\"$dst\"}"
}

rename_remote() {
	local src="$1"
	local dst="$2"
	api_json POST "/api/files/rename" "{\"src\":\"$src\",\"dst\":\"$dst\"}"
}

upload_local() {
	local local_path="$1"
	local remote_dir="$2"
	local remote_filename="${3:-$(basename "$local_path")}"

	curl -sS -X POST "$API_URL/api/files/upload" \
		-H "Authorization: Bearer $TOKEN" \
		-F "file=@$local_path" \
		-F "filename=$remote_filename" \
		-F "path=$remote_dir"
}

download_remote() {
	local remote_path="$1"
	local local_path="$2"

	mkdir -p "$(dirname "$local_path")"
	curl -sS "$API_URL/api/files/download/$remote_path" \
		-H "Authorization: Bearer $TOKEN" \
		-o "$local_path"
}

print_ls() {
	jq -r '
		.items[]?
		| "\(.type // "?")\t\(.size // 0)\t\(.modified // "-")\t\(.path // .name // "")"
	' | while IFS=$'\t' read -r type size modified path; do
		printf '%-6s %10s %s %s\n' "$type" "$size" "$modified" "$path"
	done
}

main() {
	require_cmd curl
	require_cmd jq

	API_URL="${API_URL:-http://kiosk.local}"
	PIN="${PIN:-1234}"
	REMOTE_PATH_PREFIX="${REMOTE_PATH_PREFIX:-}"

	local args=()
	while [[ $# -gt 0 ]]; do
		case "$1" in
			-u|--url)
				[[ $# -ge 2 ]] || die "Missing value for $1"
				API_URL="$2"
				shift 2
				;;
			-p|--pin)
				[[ $# -ge 2 ]] || die "Missing value for $1"
				PIN="$2"
				shift 2
				;;
			--path)
				[[ $# -ge 2 ]] || die "Missing value for $1"
				REMOTE_PATH_PREFIX="${2#/}"
				shift 2
				;;
			-h|--help)
				usage
				return 0
				;;
			--)
				shift
				args+=("$@")
				break
				;;
			*)
				args+=("$1")
				shift
				;;
		esac
	done

	[[ ${#args[@]} -ge 1 ]] || { usage; return 0; }

	set -- "${args[@]}"

	local command="$1"
	shift

	case "$command" in
		-h|--help|help)
			usage
			return 0
			;;
	esac

	auth_login

	case "$command" in
		ls)
			local remote_path
			remote_path="$(normalize_remote_path "${1:-/}")"
			list_remote "$remote_path" | print_ls
			;;
		info)
			[[ $# -ge 1 ]] || die "info requires PATH"
			local remote_path
			remote_path="$(normalize_remote_path "$1")"
			info_remote "$remote_path" | jq .
			;;
		mkdir)
			[[ $# -ge 1 ]] || die "mkdir requires PATH"
			local remote_path
			remote_path="$(normalize_remote_path "$1")"
			mkdir_remote "$remote_path" | jq .
			;;
		rmdir)
			[[ $# -ge 1 ]] || die "rmdir requires PATH"
			local remote_path
			remote_path="$(normalize_remote_path "$1")"
			rmdir_remote "$remote_path" | jq .
			;;
		rm)
			[[ $# -ge 1 ]] || die "rm requires PATH"
			local remote_path
			remote_path="$(normalize_remote_path "$1")"
			rm_remote "$remote_path" | jq .
			;;
		mv)
			[[ $# -ge 2 ]] || die "mv requires SRC DST"
			local src dst
			src="$(normalize_remote_path "$1")"
			dst="$(normalize_remote_path "$2")"
			mv_remote "$src" "$dst" | jq .
			;;
		rename)
			[[ $# -ge 2 ]] || die "rename requires SRC DST"
			local src dst
			src="$(normalize_remote_path "$1")"
			dst="$(normalize_remote_path "$2")"
			rename_remote "$src" "$dst" | jq .
			;;
		upload)
			[[ $# -ge 1 ]] || die "upload requires LOCAL [REMOTE_DIR]"
			local local_path remote_dir remote_filename
			local_path="$1"
			remote_dir="$(normalize_remote_path "${2:-/}")"
			remote_filename="${3:-}"
			[[ -f "$local_path" ]] || die "Missing local file: $local_path"
			upload_local "$local_path" "$remote_dir" "$remote_filename" | jq .
			;;
		download)
			[[ $# -ge 1 ]] || die "download requires REMOTE [LOCAL]"
			local remote_path local_path
			remote_path="$(normalize_remote_path "$1")"
			local_path="${2:-./$(basename "$remote_path")}"
			download_remote "$remote_path" "$local_path"
			echo "Downloaded to $local_path"
			;;
		help|--help|-h)
			usage
			;;
		*)
			die "Unknown command: $command"
			;;
	esac
}

main "$@"
