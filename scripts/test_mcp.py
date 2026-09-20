#!/usr/bin/env python3
"""Exercise the real stdio server with a temporary database; no MCP client dependency."""
import json
import pathlib
import queue
import sqlite3
import subprocess
import sys
import tempfile
import threading


class Client:
    def __init__(self, binary, database):
        self.process = subprocess.Popen([binary, '--database', str(database)], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.messages = queue.Queue()
        self.counter = 0
        def read():
            for line in self.process.stdout:
                self.messages.put(json.loads(line))
        threading.Thread(target=read, daemon=True).start()
        result = self.request('initialize', {'protocolVersion': '2025-11-25',
            'capabilities': {}, 'clientInfo': {'name': 'tix-smoke', 'version': '1'}})
        assert result['serverInfo']['name'] == 'tix', result
        self.send({'jsonrpc': '2.0', 'method': 'notifications/initialized'})

    def send(self, message):
        self.process.stdin.write(json.dumps(message) + '\n')
        self.process.stdin.flush()

    def request(self, method, params):
        self.counter += 1
        self.send({'jsonrpc': '2.0', 'id': self.counter, 'method': method, 'params': params})
        while True:
            message = self.messages.get(timeout=10)
            if message.get('id') == self.counter:
                assert 'error' not in message, message
                return message['result']

    def tool(self, name, error=False, **args):
        result = self.request('tools/call', {'name': name, 'arguments': args})
        assert bool(result.get('isError')) == error, result
        assert result['structuredContent'] == json.loads(result['content'][0]['text'])
        return result['structuredContent']

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            self.process.wait(timeout=5)
            raise AssertionError('MCP server did not exit when stdin closed')
        assert self.process.returncode == 0, self.process.stderr.read()


def run(binary):
    with tempfile.TemporaryDirectory(prefix='tix-mcp-') as folder:
        database = pathlib.Path(folder) / 'tickets.sqlite'
        # Seed a pre-priority workspace to verify migration preserves existing data.
        with sqlite3.connect(database) as legacy:
            legacy.executescript("""
                CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);
                INSERT INTO grdb_migrations VALUES ('v1');
                CREATE TABLE tickets (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    title TEXT NOT NULL CHECK(length(trim(title)) > 0),
                    body TEXT NOT NULL DEFAULT '',
                    status TEXT NOT NULL DEFAULT 'open' CHECK(status IN ('open','active','done')),
                    owner TEXT, createdAt REAL NOT NULL, updatedAt REAL NOT NULL,
                    revision INTEGER NOT NULL DEFAULT 1
                );
                CREATE TABLE dependencies (
                    ticket INTEGER NOT NULL REFERENCES tickets(id),
                    prerequisite INTEGER NOT NULL REFERENCES tickets(id),
                    PRIMARY KEY(ticket, prerequisite), CHECK(ticket != prerequisite)
                );
                CREATE INDEX dependencies_by_prerequisite ON dependencies(prerequisite);
                INSERT INTO tickets(title, body, status, createdAt, updatedAt)
                    VALUES ('Legacy ticket', 'Preserved body', 'done', 1, 1);
            """)
        client = Client(binary, database)
        other = None
        try:
            tools = client.request('tools/list', {})['tools']
            assert len(tools) == 10
            migrated = client.tool('get_ticket', id=1)['ticket']
            assert migrated['priority'] == migrated['effectivePriority'] == 'normal'
            assert migrated['body'] == 'Preserved body' and migrated['revision'] == 1
            a = client.tool('create_ticket', title='Define interface')['ticket']
            b = client.tool('create_ticket', title='Implement interface', body='Pass contract tests')['ticket']
            client.tool('add_dependency', id=b['id'], prerequisite=a['id'])
            assert [t['id'] for t in client.tool('list_tickets', ready=True)['tickets']] == [a['id']]
            blocked = client.tool('claim_ticket', error=True, id=b['id'], owner='bob')
            assert blocked['ticket']['blockers'] == [a['id']]
            client.tool('claim_ticket', id=a['id'], owner='alice')
            other = Client(binary, database)
            conflict = other.tool('claim_ticket', error=True, id=a['id'], owner='bob')
            assert conflict['code'] == 'conflict' and conflict['ticket']['owner'] == 'alice'
            client.tool('complete_ticket', id=a['id'])
            client.tool('claim_ticket', id=b['id'], owner='bob')
            client.tool('edit_ticket', error=True, id=b['id'], title='Stale edit', expectedRevision=b['revision'])
            current = client.tool('get_ticket', id=b['id'])['ticket']
            client.tool('edit_ticket', id=b['id'], body='Updated details', expectedRevision=current['revision'])
            client.tool('add_dependency', error=True, id=a['id'], prerequisite=b['id'])
            client.tool('release_ticket', id=b['id'])
            client.tool('complete_ticket', id=b['id'])
            client.tool('reopen_ticket', id=b['id'])
            client.tool('remove_dependency', id=b['id'], prerequisite=a['id'])
            assert client.tool('get_ticket', id=b['id'])['ticket']['ready']
            assert client.tool('get_ticket', id=a['id'])['ticket']['dependents'] == []
            client.tool('list_tickets', error=True, ready='yes')
            client.tool('list_tickets', error=True, status='unknown')
            client.tool('get_ticket', error=True, id=999)
            client.tool('create_ticket', error=True, title=' ')
            client.tool('create_ticket', error=True, title='Unexpected field', surprise=True)
            assert a['priority'] == 'normal' and a['effectivePriority'] == 'normal'
            urgent = client.tool('create_ticket', title='Urgent follow-up', priority='urgent')['ticket']
            client.tool('add_dependency', id=urgent['id'], prerequisite=b['id'])
            assert client.tool('get_ticket', id=b['id'])['ticket']['effectivePriority'] == 'urgent'
            assert client.tool('list_tickets', ready=True)['tickets'][0]['id'] == b['id']
            client.tool('edit_ticket', id=urgent['id'], priority='low')
            assert other.tool('get_ticket', id=b['id'])['ticket']['effectivePriority'] == 'normal'
            client.tool('create_ticket', error=True, title='Invalid', priority='critical')
            client.tool('edit_ticket', error=True, id=b['id'], priority='critical')
            print('MCP smoke passed: initialization, tools, lifecycle, dependencies, conflicts, validation, two processes.')
        finally:
            if other:
                other.close()
            client.close()
        missing = pathlib.Path(folder) / 'missing.sqlite'
        failure = subprocess.run([binary, '--database', str(missing)], capture_output=True, text=True, timeout=10)
        assert failure.returncode != 0 and not missing.exists()
        assert not failure.stdout
        print('Missing workspace rejected without creating a database.')


if __name__ == '__main__':
    run(str(pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else '.build/debug/tix-mcp').resolve()))
