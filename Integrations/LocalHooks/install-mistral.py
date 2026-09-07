"""Explicit-action installer; preserves all user text outside a checked block."""
import argparse
import hashlib
import importlib.metadata
import json
import math
import os
from pathlib import Path
import re
import shlex
import stat
import tempfile
import tomllib
import uuid

BEGIN = '# BEGIN LOOPFWD MISTRAL OBSERVER v1 '
END = '# END LOOPFWD MISTRAL OBSERVER v1\n'


def private_directory(directory):
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = directory.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        raise ValueError('unsafe_directory')
    directory.chmod(0o700)


def read_config(file):
    if not file.exists() and not file.is_symlink():
        return None
    info = file.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_size > 1024 * 1024:
        raise ValueError('unsafe_config')
    return file.read_bytes()


def remove_block(text, provider='mistral'):
    begin, end_marker = BEGIN.replace('MISTRAL', provider.upper()), END.replace('MISTRAL', provider.upper())
    if begin not in text and end_marker.strip() not in text:
        return text, False
    if text.count(begin) != 1 or text.count(end_marker.strip()) != 1:
        raise ValueError('edited_block')
    start = text.index(begin)
    header_end = text.find('\n', start)
    end = text.find(end_marker, header_end)
    if start == 0 or text[start - 1] != '\n' or header_end < 0 or end < 0:
        raise ValueError('edited_block')
    digest = text[start + len(begin):header_end]
    body = text[header_end + 1:end]
    if hashlib.sha256(body.encode()).hexdigest() != digest:
        raise ValueError('edited_block')
    before, after = text[:start - 1], text[end + len(end_marker):]
    inline = provider == 'kimi' and body.startswith('# inline hooks array\n')
    separator = '\n' if not inline and before and after and not before.endswith('\n') and not after.startswith('\n') else ''
    return before + separator + after, True


def inline_hooks_start(text):
    """Locate an inline root array, then prove the location with a TOML parse.

    Strings/comments may contain brackets or fake assignments. The semantic
    replacement probe prevents treating a nested key or string as root hooks.
    """
    expected = tomllib.loads(text)
    if 'hooks' not in expected:
        return None
    probe = [{'event': 'SessionStart', 'command': '__loopfwd_location_probe__'}]
    expected['hooks'] = probe
    pattern = r'(?m)^\s*(?:hooks|"hooks"|\'hooks\')\s*=\s*\['
    for attempt, match in enumerate(re.finditer(pattern, text)):
        if attempt >= 32:
            raise ValueError('hook_layout_budget')
        opening, index, depth, quote = match.end() - 1, match.end(), 1, None
        while index < len(text):
            char = text[index]
            if quote:
                if quote[0] == '"' and char == '\\':
                    index += 2
                    continue
                if text.startswith(quote, index):
                    index += len(quote)
                    if len(quote) == 3:
                        # TOML permits one/two quotes immediately before a
                        # triple-string terminator (four/five-quote runs).
                        while index < len(text) and text[index] == quote[0]:
                            index += 1
                    quote = None
                    continue
            elif char == '#':
                newline = text.find('\n', index)
                index = len(text) if newline < 0 else newline
                continue
            elif char in ('"', "'"):
                quote = char * 3 if text.startswith(char * 3, index) else char
                index += len(quote)
                continue
            elif char == '[':
                depth += 1
            elif char == ']':
                depth -= 1
                if depth == 0:
                    replacement = '[{event="SessionStart",command="__loopfwd_location_probe__"}]'
                    try:
                        if tomllib.loads(text[:opening] + replacement + text[index + 1:]) == expected:
                            return opening + 1
                    except tomllib.TOMLDecodeError:
                        pass
                    break
            index += 1
    return None


def render(old, node, collector, provider='mistral', data_root=None):
    text, _ = remove_block(old, provider)
    body = ''
    argv = [str(node), str(collector), '--provider', provider]
    if provider == 'kimi':
        argv += ['--data-root', str(data_root)]
    command = shlex.join(argv)
    event_names = ['SessionStart', 'SessionHeartbeat', 'SessionEnd'] if provider == 'kimi' else ['pre_tool', 'post_tool', 'post_agent']
    inline_start = inline_hooks_start(text) if provider == 'kimi' else None
    if inline_start is not None:
        body = '# inline hooks array\n' + ''.join(
            '{ event = ' + json.dumps(event) + ', command = ' + json.dumps(command, ensure_ascii=False) + ', timeout = 2 },\n'
            for event in event_names)
        digest = hashlib.sha256(body.encode()).hexdigest()
        block = '\n' + BEGIN.replace('MISTRAL', 'KIMI') + digest + '\n' + body + END.replace('MISTRAL', 'KIMI')
        return text[:inline_start] + block + text[inline_start:]
    for event in event_names:
        definition = f'event = "{event}"\n' if provider == 'kimi' else f'name = "loopfwd-observe-{event}"\ntype = "{event}"\n'
        body += ('[[hooks]]\n' + definition + 'command = ' + json.dumps(command, ensure_ascii=False)
                 + '\ntimeout = 2\n' + ('' if provider == 'kimi' else 'strict = false\n') + '\n')
    digest = hashlib.sha256(body.encode()).hexdigest()
    return text + '\n' + BEGIN.replace('MISTRAL', provider.upper()) + digest + '\n' + body + END.replace('MISTRAL', provider.upper())


def validate_kimi(text):
    # Mirrors the pinned 0.41.0 strict HookDefSchema, not the full model config.
    hooks = tomllib.loads(text).get('hooks', [])
    events = {'PreToolUse', 'PostToolUse', 'PostToolUseFailure', 'PermissionRequest', 'PermissionResult',
              'UserPromptSubmit', 'UserPromptQueued', 'TurnStarted', 'Stop', 'StopFailure', 'Interrupt',
              'SessionStart', 'SessionEnd', 'SessionHeartbeat', 'SubagentStart', 'SubagentStop', 'TaskStarted',
              'PreCompact', 'PostCompact', 'Notification'}
    if not isinstance(hooks, list):
        raise ValueError('invalid_kimi_hooks')
    for hook in hooks:
        if (not isinstance(hook, dict) or set(hook) - {'event', 'matcher', 'command', 'timeout'}
                or hook.get('event') not in events or not isinstance(hook.get('command'), str) or not hook['command']
                or ('matcher' in hook and not isinstance(hook['matcher'], str))
                or ('timeout' in hook and (type(hook['timeout']) not in (int, float) or not math.isfinite(hook['timeout'])
                    or hook['timeout'] != int(hook['timeout']) or not 1 <= hook['timeout'] <= 600))):
            raise ValueError('invalid_kimi_hooks')


def validate_kimi_installation(cli):
    entry = cli.resolve(strict=True)
    package = entry.parent.parent / 'package.json'
    if entry.name != 'main.mjs' or entry.parent.name != 'dist' or package.stat().st_size > 128 * 1024:
        raise ValueError('unsupported_kimi_installation')
    info = json.loads(package.read_text())
    if info.get('name') != '@moonshot-ai/kimi-code' or info.get('version') != '0.41.0':
        raise ValueError('unsupported_kimi_version')


def validate(text):
    parsed = tomllib.loads(text)
    names = [item['name'] for item in parsed.get('hooks', [])]
    if len(names) != len(set(names)):
        raise ValueError('duplicate_hook_names')
    # This is the installed provider's validator, not an approximate TOML schema.
    from vibe.core.hooks.models import HookConfig
    for item in parsed.get('hooks', []):
        HookConfig.model_validate(item)


def atomic_write(file, data):
    descriptor, temporary = tempfile.mkstemp(prefix='.loopfwd-', dir=file.parent)
    try:
        with os.fdopen(descriptor, 'wb') as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, file)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def configure(config, operation, node=None, collector=None, validator=None, write=atomic_write, provider='mistral'):
    if provider not in {'mistral', 'kimi'}:
        raise ValueError('unsupported_provider')
    validator = validator or (validate_kimi if provider == 'kimi' else validate)
    filename = 'config.toml' if provider == 'kimi' else 'hooks.toml'
    if config.name != filename or not config.is_absolute() or not config.parent.is_dir():
        raise ValueError('invalid_config_location')
    original = read_config(config)
    old = (original or b'').decode('utf-8')
    _, installed = remove_block(old, provider)
    if operation == 'check':
        return {'ok': True, 'installed': installed, 'changed': False}
    if operation == 'install':
        validator(old)
    directory = config.parent / '.loopfwd-observer'
    if operation == 'install':
        if not node or not node.is_absolute() or not os.access(node, os.X_OK) or not collector:
            raise ValueError('missing_runtime')
        code = collector.read_bytes()
        if len(code) > 1024 * 1024:
            raise ValueError('invalid_collector')
        destination = directory / (hashlib.sha256(code).hexdigest() + '.mjs')
        new = render(old, node, destination, provider, config.parent)
    elif operation == 'remove':
        new, _ = remove_block(old, provider)
    else:
        raise ValueError('invalid_operation')
    if operation == 'install':
        validator(new)
    runtime_intact = operation != 'install' or (destination.exists() and not destination.is_symlink()
                       and stat.S_ISREG(destination.stat().st_mode) and destination.stat().st_size == len(code)
                       and destination.read_bytes() == code
                       and destination.stat().st_mode & 0o777 == 0o600)
    if new == old and runtime_intact:
        return {'ok': True, 'installed': installed, 'changed': False}
    private_directory(directory)
    # A cooperating second installer cannot race this transaction.
    import fcntl
    descriptor = os.open(directory / 'install.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    backup = None
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if read_config(config) != original:
            raise ValueError('config_changed')
        backup = directory / ('backup-' + uuid.uuid4().hex)
        private_directory(backup)
        atomic_write(backup / 'original.json', json.dumps({'existed': original is not None}).encode())
        atomic_write(backup / filename, original or b'')
        if operation == 'install':
            if destination.exists() or destination.is_symlink():
                if (destination.is_symlink() or not stat.S_ISREG(destination.stat().st_mode)
                        or destination.stat().st_size != len(code) or destination.read_bytes() != code):
                    raise ValueError('collector_changed')
                destination.chmod(0o600)
            else:
                atomic_write(destination, code)
        if read_config(config) != original:
            raise ValueError('config_changed')
        write(config, new.encode())
        if read_config(config) != new.encode():
            raise ValueError('write_verification_failed')
        return {'ok': True, 'installed': operation == 'install', 'changed': True, 'backupPath': str(backup)}
    except Exception:
        # Restore only our exact write; never overwrite an intervening user edit.
        if read_config(config) == new.encode():
            if original is None:
                config.unlink()
            else:
                atomic_write(config, original)
        if backup:
            return {'ok': False, 'code': 'operation_failed', 'backupPath': str(backup)}
        raise
    finally:
        os.close(descriptor)


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser()
    parser.add_argument('operation', choices=['install', 'remove', 'check'])
    parser.add_argument('--config', required=True, type=Path)
    parser.add_argument('--node', type=Path)
    parser.add_argument('--collector', type=Path)
    parser.add_argument('--provider', choices=['mistral', 'kimi'], default='mistral')
    parser.add_argument('--cli', type=Path)
    arguments = parser.parse_args()
    try:
        if arguments.operation == 'install':
            if arguments.provider == 'kimi':
                if not arguments.cli:
                    raise ValueError('missing_cli')
                validate_kimi_installation(arguments.cli)
            elif importlib.metadata.version('mistral-vibe') != '2.25.0':
                raise ValueError('unsupported_version')
        result = configure(arguments.config, arguments.operation, arguments.node, arguments.collector, provider=arguments.provider)
    except Exception as error:
        code = str(error) if isinstance(error, ValueError) and re.fullmatch('[a-z_]+', str(error)) else 'invalid_config_or_runtime'
        result = {'ok': False, 'code': code}
    print(json.dumps(result))
    raise SystemExit(0 if result['ok'] else 1)


if __name__ == '__main__':
    main()
