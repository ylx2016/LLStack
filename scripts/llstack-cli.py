#!/usr/bin/env python3

import argparse
import urllib.request
import urllib.parse
import json
import hashlib
import getpass
import os
import sys


DEFAULT_URL = "http://127.0.0.1:8001"
TOKEN_PATH = os.path.expanduser("~/.llstack-cli-token")
BASE64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
AUTH_ERROR_MESSAGES = {
    "missing_token",
    "token_expired",
    "invalid_token",
    "user_not_found",
}


class APIError(Exception):
    def __init__(self, message, status=None, payload=None, message_key=None):
        super().__init__(message)
        self.status = status
        self.payload = payload
        self.message_key = message_key


def humanize_message(message):
    mapping = {
        "invalid_credentials": "Invalid username or password",
        "token_expired": "Saved session expired",
        "missing_token": "Authentication required",
        "invalid_token": "Invalid saved session token",
        "user_not_found": "User for saved session token no longer exists",
        "admin_required": "This action requires an admin account",
        "altcha_failed": "ALTCHA verification failed",
        "domain_required": "Domain is required",
        "domain_exists": "A site with that domain already exists",
        "site_not_found": "Site not found",
        "log_not_found": "Log not found",
        "backup_not_found": "Backup not found",
        "invalid_php_version": "Invalid PHP version",
        "invalid_backup_type": "Invalid backup type",
        "access_denied": "Access denied",
        "not_found": "Endpoint not found",
    }
    if not message:
        return "Request failed"
    if message in mapping:
        return mapping[message]
    return message.replace("_", " ").strip().capitalize()


def format_bytes(value):
    try:
        size = float(value or 0)
    except Exception:
        return "0 B"
    units = ["B", "KB", "MB", "GB", "TB", "PB"]
    index = 0
    while size >= 1024 and index < len(units) - 1:
        size /= 1024.0
        index += 1
    if index == 0:
        return "%d %s" % (int(size), units[index])
    return "%.1f %s" % (size, units[index])


def format_duration(seconds):
    try:
        total = int(seconds or 0)
    except Exception:
        total = 0
    days = total // 86400
    total %= 86400
    hours = total // 3600
    total %= 3600
    minutes = total // 60
    secs = total % 60
    parts = []
    if days:
        parts.append("%dd" % days)
    if hours:
        parts.append("%dh" % hours)
    if minutes:
        parts.append("%dm" % minutes)
    if secs or not parts:
        parts.append("%ds" % secs)
    return " ".join(parts)


def format_percent(value):
    try:
        return "%.1f%%" % float(value or 0)
    except Exception:
        return "0.0%"


def bool_text(value):
    return "yes" if value else "no"


def normalize_url(url):
    return (url or DEFAULT_URL).strip().rstrip("/")


def join_url(base_url, path):
    if not path.startswith("/"):
        path = "/" + path
    return normalize_url(base_url) + path


def read_json_bytes(raw):
    if not raw:
        return {}
    text = raw.decode("utf-8", "replace")
    if not text.strip():
        return {}
    try:
        return json.loads(text)
    except Exception:
        raise APIError("Server returned invalid JSON")


def extract_error_details(status, body_text, payload, reason):
    message_key = None
    if isinstance(payload, dict):
        message_key = payload.get("message") or payload.get("error")
    if message_key:
        message = humanize_message(message_key)
        if status:
            return "HTTP %s: %s" % (status, message), message_key
        return message, message_key
    if reason:
        return "Connection failed: %s" % reason, None
    if body_text:
        snippet = body_text.strip().splitlines()[0][:200]
        if status:
            return "HTTP %s: %s" % (status, snippet), None
        return snippet, None
    if status:
        return "HTTP %s request failed" % status, None
    return "Request failed", None


def request_json(base_url, path, method="GET", payload=None, token=None, expect_wrapped=True):
    url = join_url(base_url, path)
    data = None
    headers = {
        "Accept": "application/json",
        "User-Agent": "llstack-cli/1.0",
    }
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = "Bearer %s" % token
    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            raw = response.read()
            parsed = read_json_bytes(raw)
    except Exception as exc:
        status = getattr(exc, "code", None)
        reason = getattr(exc, "reason", None)
        body_text = ""
        parsed = None
        if hasattr(exc, "read"):
            try:
                error_bytes = exc.read()
                body_text = error_bytes.decode("utf-8", "replace")
                try:
                    parsed = json.loads(body_text) if body_text.strip() else None
                except Exception:
                    parsed = None
            except Exception:
                body_text = ""
        message, message_key = extract_error_details(status, body_text, parsed, reason)
        raise APIError(message, status=status, payload=parsed, message_key=message_key)

    if not expect_wrapped:
        return parsed

    if not isinstance(parsed, dict) or "code" not in parsed:
        raise APIError("Unexpected response format from server")

    if parsed.get("code") != 0:
        message_key = parsed.get("message")
        raise APIError(
            humanize_message(message_key),
            status=200,
            payload=parsed,
            message_key=message_key,
        )
    return parsed.get("data")


def load_token():
    try:
        with open(TOKEN_PATH, "r", encoding="utf-8") as handle:
            token = handle.read().strip()
            return token or None
    except FileNotFoundError:
        return None
    except Exception:
        return None


def save_token(token):
    with open(TOKEN_PATH, "w", encoding="utf-8") as handle:
        handle.write((token or "").strip())
        handle.write("\n")
    try:
        os.chmod(TOKEN_PATH, 0o600)
    except Exception:
        pass


def clear_token():
    try:
        os.remove(TOKEN_PATH)
    except FileNotFoundError:
        pass
    except Exception:
        pass


def encode_base64(data):
    output = []
    index = 0
    while index < len(data):
        chunk = data[index:index + 3]
        block = chunk + b"\x00" * (3 - len(chunk))
        value = (block[0] << 16) | (block[1] << 8) | block[2]
        output.append(BASE64_ALPHABET[(value >> 18) & 63])
        output.append(BASE64_ALPHABET[(value >> 12) & 63])
        output.append(BASE64_ALPHABET[(value >> 6) & 63] if len(chunk) > 1 else "=")
        output.append(BASE64_ALPHABET[value & 63] if len(chunk) > 2 else "=")
        index += 3
    return "".join(output)


def solve_altcha(base_url):
    challenge = request_json(base_url, "/api/auth/altcha-challenge", expect_wrapped=False)
    if not isinstance(challenge, dict):
        raise APIError("ALTCHA challenge response was invalid")
    algorithm = (challenge.get("algorithm") or "").upper()
    if algorithm != "SHA-256":
        raise APIError("Unsupported ALTCHA algorithm: %s" % (challenge.get("algorithm") or "unknown"))
    target = challenge.get("challenge")
    salt = challenge.get("salt")
    signature = challenge.get("signature")
    try:
        max_number = int(challenge.get("maxnumber"))
    except Exception:
        raise APIError("ALTCHA challenge is missing maxnumber")
    if not target or salt is None or not signature:
        raise APIError("ALTCHA challenge is incomplete")

    number = None
    current = 0
    while current <= max_number:
        digest = hashlib.sha256((str(salt) + str(current)).encode("utf-8")).hexdigest()
        if digest == target:
            number = current
            break
        current += 1

    if number is None:
        raise APIError("Could not solve ALTCHA challenge")

    payload = {
        "algorithm": challenge.get("algorithm"),
        "challenge": target,
        "number": number,
        "salt": salt,
        "signature": signature,
    }
    encoded = encode_base64(json.dumps(payload, separators=(",", ":")).encode("utf-8"))
    return payload, encoded


def verify_token(base_url, token):
    request_json(base_url, "/api/auth/me", token=token)
    return token


def login(base_url):
    username = input("Username: ").strip()
    password = getpass.getpass("Password: ")
    _, encoded_altcha = solve_altcha(base_url)
    data = request_json(
        base_url,
        "/api/auth/login",
        method="POST",
        payload={
            "username": username,
            "password": password,
            "altcha": encoded_altcha,
        },
    )

    if isinstance(data, dict) and data.get("requires_2fa"):
        temp_token = data.get("temp_token")
        if not temp_token:
            raise APIError("Server requested 2FA but did not provide a temporary token")
        totp_code = input("2FA code: ").strip()
        data = request_json(
            base_url,
            "/api/auth/login",
            method="POST",
            payload={
                "temp_token": temp_token,
                "totp_code": totp_code,
            },
        )

    token = data.get("token") if isinstance(data, dict) else None
    if not token:
        raise APIError("Login succeeded but server did not return a token")
    save_token(token)
    return token


def ensure_token(base_url, force_login=False):
    token = None if force_login else load_token()
    if token:
        try:
            return verify_token(base_url, token)
        except APIError as exc:
            if exc.status == 401 or exc.message_key in AUTH_ERROR_MESSAGES:
                clear_token()
            else:
                raise
    return login(base_url)


def authed_request(base_url, path, method="GET", payload=None, expect_wrapped=True):
    token = ensure_token(base_url)
    try:
        return request_json(
            base_url,
            path,
            method=method,
            payload=payload,
            token=token,
            expect_wrapped=expect_wrapped,
        )
    except APIError as exc:
        if exc.status == 401 or exc.message_key in AUTH_ERROR_MESSAGES:
            clear_token()
            token = ensure_token(base_url, force_login=True)
            return request_json(
                base_url,
                path,
                method=method,
                payload=payload,
                token=token,
                expect_wrapped=expect_wrapped,
            )
        raise


def request_with_fallback(base_url, paths, method="GET", payload=None):
    last_error = None
    for path in paths:
        try:
            return authed_request(base_url, path, method=method, payload=payload)
        except APIError as exc:
            last_error = exc
            if exc.status == 404 or exc.message_key == "not_found":
                continue
            raise
    if last_error:
        raise last_error
    raise APIError("Request failed")


def pad(value, width):
    text = "" if value is None else str(value)
    if len(text) >= width:
        return text
    return text + (" " * (width - len(text)))


def print_table(headers, rows):
    if not rows:
        return
    widths = []
    for index, header in enumerate(headers):
        width = len(str(header))
        for row in rows:
            if index < len(row):
                width = max(width, len(str(row[index])))
        widths.append(width)
    print("  ".join(pad(headers[i], widths[i]) for i in range(len(headers))))
    print("  ".join("-" * widths[i] for i in range(len(headers))))
    for row in rows:
        print("  ".join(pad(row[i], widths[i]) for i in range(len(headers))))


def print_labeled_rows(rows):
    if not rows:
        return
    width = 0
    for label, _value in rows:
        width = max(width, len(str(label)))
    for label, value in rows:
        print("%s  %s" % (pad(label, width), value))


def fetch_all_sites(base_url):
    page = 1
    per_page = 100
    items = []
    total = None
    while True:
        data = authed_request(base_url, "/api/sites?page=%d&per_page=%d" % (page, per_page))
        page_items = data.get("items") or []
        items.extend(page_items)
        total = data.get("total")
        if len(page_items) < per_page:
            break
        if total is not None and len(items) >= int(total):
            break
        page += 1
    return items


def cmd_status(base_url, _args):
    health = request_json(base_url, "/api/health", expect_wrapped=False)
    stats = authed_request(base_url, "/api/system/stats")

    cpu = stats.get("cpu") or {}
    memory = stats.get("memory") or {}
    disk = stats.get("disk") or {}
    os_info = stats.get("os") or {}
    services = stats.get("services") or {}

    print("LLStack Panel Status")
    print("")
    print_labeled_rows([
        ("Panel version", stats.get("panel_version") or health.get("version") or "-"),
        ("Health", health.get("status") or "-"),
        ("Database", bool_text(health.get("db"))),
        ("OS", "%s %s" % ((os_info.get("name") or "").strip(), (os_info.get("version") or "").strip())),
        ("Kernel", os_info.get("kernel") or "-"),
        ("Architecture", os_info.get("arch") or "-"),
        ("CPU", "%s used, %s cores" % (format_percent(cpu.get("usage_percent")), cpu.get("cores") or "-")),
        ("CPU model", cpu.get("model") or "-"),
        ("Memory", "%s / %s (%s)" % (
            format_bytes(memory.get("used_bytes")),
            format_bytes(memory.get("total_bytes")),
            format_percent(memory.get("usage_percent")),
        )),
        ("Disk", "%s / %s (%s)" % (
            format_bytes(disk.get("used_bytes")),
            format_bytes(disk.get("total_bytes")),
            format_percent(disk.get("usage_percent")),
        )),
        ("Load", " ".join(str(x) for x in (stats.get("load") or [])) or "-"),
        ("Uptime", format_duration(stats.get("uptime_seconds"))),
        ("Sites", stats.get("sites_count") or 0),
        ("Users", stats.get("users_count") or 0),
        ("Databases", stats.get("db_count") or 0),
        ("Backups", stats.get("backup_count") or 0),
        ("Cron jobs", stats.get("cron_count") or 0),
    ])

    print("")
    print("Services")
    if services:
        rows = []
        for name in sorted(services):
            rows.append([name, services.get(name)])
        print_table(["Service", "Status"], rows)
    else:
        print("No services reported.")


def cmd_sites_list(base_url, _args):
    items = fetch_all_sites(base_url)
    if not items:
        print("No sites found.")
        return
    rows = []
    for item in items:
        rows.append([
            item.get("domain") or "-",
            item.get("status") or "-",
            item.get("php_version") or "-",
        ])
    print_table(["Domain", "Status", "PHP"], rows)


def cmd_sites_create(base_url, args):
    result = authed_request(
        base_url,
        "/api/sites",
        method="POST",
        payload={
            "domain": args.domain.strip().lower(),
            "php_version": args.php_version.strip(),
        },
    )
    print("Site created")
    print("")
    print_labeled_rows([
        ("ID", result.get("id") or "-"),
        ("Domain", result.get("domain") or "-"),
        ("Status", result.get("status") or "-"),
        ("PHP", result.get("php_version") or "-"),
        ("Doc root", result.get("doc_root") or "-"),
    ])
    if result.get("task_id"):
        print("Task ID  %s" % result.get("task_id"))


def cmd_php_list(base_url, _args):
    data = authed_request(base_url, "/api/php/versions")
    installed = data.get("installed") or []
    if not installed:
        print("No PHP versions installed.")
        return
    rows = []
    for item in installed:
        rows.append([
            item.get("version") or "-",
            item.get("display") or "-",
        ])
    print_table(["Version", "Display"], rows)


def cmd_backup_create(base_url, args):
    try:
        site_id = int(args.site)
    except Exception:
        raise APIError("Site ID must be an integer")
    result = request_with_fallback(
        base_url,
        ["/api/backups", "/api/backup"],
        method="POST",
        payload={
            "site_id": site_id,
            "type": "full",
        },
    )
    print("Backup created")
    print("")
    print_labeled_rows([
        ("ID", result.get("id") or "-"),
        ("Site ID", result.get("site_id") or "-"),
        ("Type", result.get("type") or "-"),
        ("Path", result.get("path") or "-"),
        ("Size", format_bytes(result.get("size"))),
        ("Created", result.get("created_at") or "-"),
    ])


def cmd_logs(base_url, args):
    # URL-encode log_id so a value containing /, ?, #, or .. cannot alter the request path/query.
    path = "/api/logs/%s?lines=%d" % (urllib.parse.quote(str(args.log_id), safe=""), int(args.lines))
    result = authed_request(base_url, path)
    lines = result.get("lines") or []
    print("Log: %s" % (result.get("display") or args.log_id))
    print("Path: %s" % (result.get("path") or "-"))
    print("Lines: %s" % (result.get("total") or 0))
    print("")
    if not lines:
        print("No log lines returned.")
        return
    for line in lines:
        print(line)


def build_parser():
    parser = argparse.ArgumentParser(
        description="CLI for the LLStack panel",
    )
    parser.add_argument(
        "--url",
        default=os.environ.get("LLSTACK_API_URL") or DEFAULT_URL,
        help="LLStack API base URL (default: %(default)s)",
    )

    subparsers = parser.add_subparsers(dest="command")
    subparsers.required = True

    status_parser = subparsers.add_parser("status", help="Show panel and system status")
    status_parser.set_defaults(func=cmd_status)

    sites_parser = subparsers.add_parser("sites", help="Manage sites")
    sites_subparsers = sites_parser.add_subparsers(dest="sites_command")
    sites_subparsers.required = True

    sites_list_parser = sites_subparsers.add_parser("list", help="List sites")
    sites_list_parser.set_defaults(func=cmd_sites_list)

    sites_create_parser = sites_subparsers.add_parser("create", help="Create a site")
    sites_create_parser.add_argument("domain", help="Domain name")
    sites_create_parser.add_argument("--php", dest="php_version", required=True, help="PHP version, for example php83")
    sites_create_parser.set_defaults(func=cmd_sites_create)

    php_parser = subparsers.add_parser("php", help="Manage PHP")
    php_subparsers = php_parser.add_subparsers(dest="php_command")
    php_subparsers.required = True

    php_list_parser = php_subparsers.add_parser("list", help="List installed PHP versions")
    php_list_parser.set_defaults(func=cmd_php_list)

    backup_parser = subparsers.add_parser("backup", help="Manage backups")
    backup_subparsers = backup_parser.add_subparsers(dest="backup_command")
    backup_subparsers.required = True

    backup_create_parser = backup_subparsers.add_parser("create", help="Create a backup")
    backup_create_parser.add_argument("--site", required=True, help="Site ID")
    backup_create_parser.set_defaults(func=cmd_backup_create)

    logs_parser = subparsers.add_parser("logs", help="Read system logs")
    logs_parser.add_argument("log_id", help="Log identifier")
    logs_parser.add_argument("--lines", type=int, default=200, help="Number of lines to show (default: %(default)s)")
    logs_parser.set_defaults(func=cmd_logs)

    return parser


def main():
    parser = build_parser()
    args = parser.parse_args()
    base_url = normalize_url(args.url)
    try:
        args.func(base_url, args)
        return 0
    except KeyboardInterrupt:
        print("Interrupted.", file=sys.stderr)
        return 130
    except APIError as exc:
        print("Error: %s" % exc, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
