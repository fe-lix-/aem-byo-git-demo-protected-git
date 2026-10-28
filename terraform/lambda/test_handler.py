import ipaddress
import json
import os
import socket
import subprocess
import unittest
from unittest.mock import MagicMock, patch

import handler


ENVIRONMENT = {
    "AWS_REGION": "us-east-1",
    "SOURCE_REPOSITORY": "demo-source",
    "DESTINATION_REPOSITORY_URL": "https://git.example.com/customer/site.git",
    "DESTINATION_SECRET_ARN": "demo-secret",
    "SYNC_BRANCH": "main",
    "ALLOWED_DESTINATION_CIDRS": json.dumps(["192.0.2.128/28"]),
}
APPROVED_ADDRESS = "192.0.2.129"
DNS_ANSWER = [(socket.AF_INET, socket.SOCK_STREAM, 6, "", (APPROVED_ADDRESS, 443))]


def resolve_with_dns_firewall(hostname, *_args, **_kwargs):
    if hostname == handler.BLOCKED_DNS_NAME:
        raise socket.gaierror(socket.EAI_NONAME, "Name or service not known")
    return DNS_ANSWER


@patch.dict(os.environ, ENVIRONMENT, clear=True)
class HandlerTests(unittest.TestCase):
    @patch.object(handler.ssl, "create_default_context")
    @patch.object(handler.socket, "create_connection")
    @patch.object(handler.socket, "getaddrinfo", side_effect=resolve_with_dns_firewall)
    def test_network_requires_positive_tls_and_blocked_public_connections(
        self, _resolve, connect, tls_context
    ):
        connect.side_effect = [MagicMock(), socket.timeout(), socket.timeout(), socket.timeout()]

        result = handler.handler({"action": "test-network"}, None)

        self.assertTrue(result["passed"])
        self.assertEqual(len(result["blocked_probes"]), 3)
        self.assertEqual(
            [call.args[0] for call in connect.call_args_list],
            [(APPROVED_ADDRESS, 443), *handler.BLOCKED_PROBES],
        )
        tls_context.return_value.wrap_socket.assert_called_once()

    @patch.object(handler.ssl, "create_default_context")
    @patch.object(handler.socket, "create_connection")
    @patch.object(handler.socket, "getaddrinfo", return_value=DNS_ANSWER)
    def test_network_fails_if_unapproved_dns_resolution_succeeds(
        self, _resolve, connect, _tls_context
    ):
        connect.side_effect = [MagicMock(), socket.timeout(), socket.timeout(), socket.timeout()]
        with self.assertRaisesRegex(RuntimeError, "DNS isolation failed"):
            handler.handler({"action": "test-network"}, None)

    @patch.object(handler.ssl, "create_default_context")
    @patch.object(handler.socket, "create_connection", return_value=MagicMock())
    @patch.object(handler.socket, "getaddrinfo", return_value=DNS_ANSWER)
    def test_network_fails_if_any_unapproved_connection_succeeds(
        self, _resolve, _connect, _tls_context
    ):
        with self.assertRaisesRegex(RuntimeError, "Egress isolation failed"):
            handler.handler({"action": "test-network"}, None)

    @patch.object(handler.socket, "create_connection", side_effect=socket.timeout())
    @patch.object(handler.socket, "getaddrinfo", return_value=DNS_ANSWER)
    def test_network_fails_without_positive_control(self, _resolve, connect):
        with self.assertRaises(socket.timeout):
            handler.handler({"action": "test-network"}, None)
        self.assertEqual(connect.call_count, 1)

    @patch.object(handler.ssl, "create_default_context")
    @patch.object(handler.socket, "create_connection")
    @patch.object(handler.socket, "getaddrinfo", return_value=DNS_ANSWER)
    def test_connection_refusal_is_not_treated_as_proof_of_isolation(
        self, _resolve, connect, _tls_context
    ):
        connect.side_effect = [MagicMock(), ConnectionRefusedError()]
        with self.assertRaises(ConnectionRefusedError):
            handler.handler({"action": "test-network"}, None)

    @patch.object(handler.socket, "getaddrinfo")
    def test_destination_dns_must_be_entirely_allowlisted(self, resolve):
        resolve.return_value = [
            *DNS_ANSWER,
            (socket.AF_INET, socket.SOCK_STREAM, 6, "", ("1.1.1.1", 443)),
        ]
        with self.assertRaisesRegex(ValueError, "outside the allowlist"):
            handler.approved_addresses(
                "git.example.com", [ipaddress.IPv4Network("192.0.2.128/28")]
            )

    def test_invoker_cannot_supply_a_destination_or_refspec(self):
        with self.assertRaisesRegex(ValueError, "Provide only action"):
            handler.handler({"action": "sync", "destination": "https://other.example/x"}, None)

    def test_rejects_destination_credentials_and_global_allowlist(self):
        with patch.dict(os.environ, {"DESTINATION_REPOSITORY_URL": "https://user:pat@git.example.com/x"}):
            with self.assertRaises(ValueError):
                handler.destination()
        with patch.dict(os.environ, {"ALLOWED_DESTINATION_CIDRS": '["0.0.0.0/0"]'}):
            with self.assertRaises(ValueError):
                handler.allowed_networks()

    @patch.object(handler, "credentials", return_value={"username": "demo-user", "pat": "demo-pat"})
    @patch.object(handler, "run_git")
    @patch.object(handler.socket, "getaddrinfo", return_value=DNS_ANSWER)
    def test_sync_clones_one_branch_and_only_exposes_pat_to_push(
        self, _resolve, git, _credentials
    ):
        result = handler.handler({"action": "sync"}, None)

        self.assertTrue(result["pushed"])
        clone, push = git.call_args_list[1:]
        self.assertEqual(
            clone.args[0][:6],
            ["clone", "--bare", "--single-branch", "--branch", "main", "codecommit::us-east-1://demo-source"],
        )
        self.assertNotIn("GIT_PUSH_PAT", clone.args[1])
        self.assertEqual(push.args[1]["GIT_PUSH_PAT"], "demo-pat")
        self.assertEqual(push.args[0][-1], "refs/heads/main:refs/heads/main")
        self.assertNotIn("--force", push.args[0])
        self.assertNotIn("demo-pat", " ".join(push.args[0]))
        self.assertEqual(push.args[1]["GIT_CONFIG_VALUE_1"], "false")

    @patch.object(handler, "credentials")
    @patch.object(handler, "run_git", side_effect=[MagicMock(), RuntimeError("Git clone failed")])
    def test_failed_clone_never_fetches_destination_credentials(self, _git, credentials):
        with self.assertRaisesRegex(RuntimeError, "clone failed"):
            handler.synchronize(ENVIRONMENT["DESTINATION_REPOSITORY_URL"])
        credentials.assert_not_called()

    @patch.object(handler.subprocess, "run")
    def test_git_errors_do_not_expose_remote_output(self, run):
        run.side_effect = subprocess.CalledProcessError(
            128, ["git", "push"], stderr="remote: demo-pat"
        )
        with self.assertRaisesRegex(RuntimeError, "Git push failed") as error:
            handler.run_git(["push"], {}, "push")
        self.assertNotIn("demo-pat", str(error.exception))


if __name__ == "__main__":
    unittest.main()
