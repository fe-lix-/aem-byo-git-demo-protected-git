import ipaddress
import json
import os
from pathlib import Path
import socket
import ssl
import subprocess
import tempfile
from urllib.parse import urlsplit


BLOCKED_PROBES = (("1.1.1.1", 443), ("8.8.8.8", 443), ("1.0.0.1", 80))
BLOCKED_DNS_NAME = "example.org"
CONNECT_TIMEOUT = 4


def destination():
    url = os.environ["DESTINATION_REPOSITORY_URL"]
    parsed = urlsplit(url)
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.port not in (None, 443)
        or not parsed.path.startswith("/")
        or parsed.path == "/"
        or parsed.query
        or parsed.fragment
        or any(character.isspace() or ord(character) < 32 for character in url)
    ):
        raise ValueError("Destination must be an HTTPS Git URL without credentials")
    return url, parsed.hostname


def allowed_networks():
    networks = [
        ipaddress.IPv4Network(cidr, strict=True)
        for cidr in json.loads(os.environ["ALLOWED_DESTINATION_CIDRS"])
    ]
    if not networks or any(network.prefixlen == 0 for network in networks):
        raise ValueError("Explicit destination IPv4 ranges are required")
    return networks


def approved_addresses(hostname, networks):
    addresses = sorted({
        result[4][0]
        for result in socket.getaddrinfo(
            hostname, 443, family=socket.AF_INET, type=socket.SOCK_STREAM
        )
    })
    if not addresses or any(
        not any(ipaddress.IPv4Address(address) in network for network in networks)
        for address in addresses
    ):
        raise ValueError("Destination DNS contains addresses outside the allowlist")
    return addresses


def test_network(hostname, networks):
    if hostname.lower() == BLOCKED_DNS_NAME:
        raise ValueError("The destination hostname is reserved for a negative DNS test")
    for address, _ in BLOCKED_PROBES:
        if any(ipaddress.IPv4Address(address) in network for network in networks):
            raise ValueError("A negative-test address is included in the allowlist")

    addresses = approved_addresses(hostname, networks)
    # A successful TLS connection is the positive control: networking must work.
    for address in addresses:
        with socket.create_connection((address, 443), CONNECT_TIMEOUT) as connection:
            with ssl.create_default_context().wrap_socket(
                connection, server_hostname=hostname
            ):
                pass

    blocked = []
    for address, port in BLOCKED_PROBES:
        try:
            with socket.create_connection((address, port), CONNECT_TIMEOUT):
                pass
        except socket.timeout:
            blocked.append({"ip": address, "port": port, "result": "timeout"})
        else:
            raise RuntimeError(
                f"Egress isolation failed: connected to {address}:{port}"
            )

    try:
        socket.getaddrinfo(BLOCKED_DNS_NAME, 443, family=socket.AF_INET)
    except socket.gaierror as error:
        if error.errno != socket.EAI_NONAME:
            raise
    else:
        raise RuntimeError("DNS isolation failed: resolved an unapproved hostname")

    return {
        "action": "test-network",
        "approved_tls_addresses": addresses,
        "blocked_probes": blocked,
        "blocked_dns_name": BLOCKED_DNS_NAME,
        "passed": True,
    }


def credentials():
    import boto3

    response = boto3.client("secretsmanager").get_secret_value(
        SecretId=os.environ["DESTINATION_SECRET_ARN"]
    )
    secret = json.loads(response["SecretString"])
    for key in ("username", "pat"):
        if (
            not isinstance(secret.get(key), str)
            or not secret[key]
            or any(ord(character) < 32 or ord(character) == 127 for character in secret[key])
        ):
            raise ValueError("Destination secret needs nonempty username and pat strings")
    return secret


def run_git(arguments, environment, operation, timeout=180):
    try:
        return subprocess.run(
            ["git", *arguments],
            env=environment,
            check=True,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.CalledProcessError as error:
        # Git output can contain remote-server text or credentials; never log it.
        raise RuntimeError(
            f"Git {operation} failed (exit {error.returncode}); check access and branch history"
        ) from None
    except subprocess.TimeoutExpired:
        raise RuntimeError(f"Git {operation} timed out") from None


def synchronize(url):
    branch = os.environ["SYNC_BRANCH"]
    with tempfile.TemporaryDirectory(prefix="git-sync-") as directory:
        environment = {
            **os.environ,
            "HOME": directory,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_ALLOW_PROTOCOL": "codecommit:https",
            "GIT_CONFIG_COUNT": "2",
            "GIT_CONFIG_KEY_0": "credential.helper",
            "GIT_CONFIG_VALUE_0": "",
            "GIT_CONFIG_KEY_1": "http.followRedirects",
            "GIT_CONFIG_VALUE_1": "false",
        }
        run_git(["check-ref-format", "--branch", branch], environment, "branch validation")
        source = (
            f"codecommit::{os.environ['AWS_REGION']}://"
            f"{os.environ['SOURCE_REPOSITORY']}"
        )
        repository = str(Path(directory) / "source.git")
        run_git(
            ["clone", "--bare", "--single-branch", "--branch", branch, source, repository],
            environment,
            "clone",
        )
        secret = credentials()
        push_environment = {
            **environment,
            "GIT_ASKPASS": str(Path(__file__).with_name("git_askpass.py")),
            "GIT_PUSH_USERNAME": secret["username"],
            "GIT_PUSH_PAT": secret["pat"],
        }
        run_git(
            [
                "-C", repository, "push", "--porcelain", url,
                f"refs/heads/{branch}:refs/heads/{branch}",
            ],
            push_environment,
            "push",
        )
    return {"action": "sync", "branch": branch, "pushed": True}


def handler(event, _context):
    if not isinstance(event, dict) or set(event) != {"action"}:
        raise ValueError("Provide only action: sync or test-network")
    url, hostname = destination()
    networks = allowed_networks()
    if event["action"] == "test-network":
        return test_network(hostname, networks)
    if event["action"] == "sync":
        approved_addresses(hostname, networks)
        return synchronize(url)
    raise ValueError("Unknown action; use sync or test-network")
