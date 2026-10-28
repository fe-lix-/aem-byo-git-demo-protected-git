"""Offline tests: python3 -m unittest discover -s scripts -p 'test_*.py'."""

import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import unittest
from unittest.mock import MagicMock, patch

spec = importlib.util.spec_from_file_location(
    "configure_byogit", Path(__file__).with_name("configure-byogit.py")
)
script = importlib.util.module_from_spec(spec)
spec.loader.exec_module(script)


class ConfigureTests(unittest.TestCase):
    def run_script(self, statuses, secret='secret-"value\\with\nnewline'):
        argv = ['script', '--org', 'org', '--site', 'site',
                '--program-id', '123', '--repo-id', '456']
        connections = [MagicMock() for _ in statuses]
        for connection, status in zip(connections, statuses):
            connection.getresponse.return_value.status = status
            connection.getresponse.return_value.read.return_value = b'sensitive-response'
        output = io.StringIO()
        with patch.dict(os.environ, {'HLX_TOKEN': 'test-token', 'CM_SECRET': secret}), \
                patch.object(script.sys, 'argv', argv), \
                patch.object(script.http.client, 'HTTPSConnection', side_effect=connections) as https, \
                patch.object(script, 'read_hidden_token') as prompt, \
                contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            try:
                result = script.main()
            except SystemExit as exc:
                result = exc.code
            prompt.assert_not_called()
        text = output.getvalue()
        for sensitive in ('test-token', secret, 'sensitive-response'):
            if sensitive:
                self.assertNotIn(sensitive, text)
        return result, connections, https.call_count

    def test_secret_then_code(self):
        result, connections, count = self.run_script([201, 200])
        self.assertEqual((result, count), (0, 2))
        args, kwargs = connections[0].request.call_args
        self.assertEqual(args, ('POST', '/config/org/sites/site/secrets/cm-byog.json'))
        self.assertEqual(json.loads(kwargs['body']), {'value': 'secret-"value\\with\nnewline'})
        self.assertEqual(kwargs['headers']['x-auth-token'], 'test-token')
        args, kwargs = connections[1].request.call_args
        self.assertEqual(args, ('POST', '/config/org/sites/site/code.json'))
        source = json.loads(kwargs['body'])['source']
        self.assertEqual((source['owner'], source['repo'], source['secretId']),
                         ('123', '456', 'cm-byog'))
        for connection in connections:
            connection.close.assert_called_once()

    def test_secret_failure_stops(self):
        result, _, count = self.run_script([403])
        self.assertEqual((result, count), (1, 1))

    def test_redirect_stops(self):
        result, _, count = self.run_script([302])
        self.assertEqual((result, count), (1, 1))

    def test_code_failure(self):
        result, _, count = self.run_script([200, 500])
        self.assertEqual((result, count), (1, 2))

    def test_empty_secret_rejected_before_requests(self):
        result, _, count = self.run_script([], secret='')
        self.assertEqual((result, count), (2, 0))


if __name__ == '__main__':
    unittest.main()
