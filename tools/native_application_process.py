"""Optional host debugger for owned synthetic native qualification only."""
import datetime
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time


def _identity(pid):
    proc = Path('/proc') / str(pid)
    try:
        fields = (proc / 'stat').read_text().rsplit(')', 1)[1].split()
        return (proc.stat().st_uid, int(fields[1]), fields[19],
                (proc / 'exe').resolve(strict=True))
    except (FileNotFoundError, ProcessLookupError):
        return None


class DebuggedApplication:
    """Expose the inferior PID to the existing native focus/input guards.

    GDB remains its parent, avoiding system ptrace-policy changes. All normal
    application arguments and environment are retained. A debugger failure is
    never interpreted as a successful application Quit.
    """

    def __init__(self, binary, startup, stream, environment, evidence,
                 *, startup_timeout=10):
        self.pid = None
        self._identity = None
        self._binary = Path(binary).resolve(strict=True)
        evidence = Path(evidence)
        self.directory = Path(tempfile.mkdtemp(prefix='quit-backtrace-', dir=evidence))
        self.directory.chmod(0o700)
        self.receipt = self.directory / 'process.json'
        pid_file = self.directory / 'inferior.pid'
        commands = [
            'set pagination off', 'set confirm off',
            'set startup-with-shell off',
            'handle SIGALRM SIGPIPE SIGTERM SIGUSR1 SIGUSR2 SIGCHLD SIGWINCH nostop noprint pass',
            'starti',
            'python open(' + repr(str(pid_file)) + ', "x").write(str(gdb.selected_inferior().pid))',
            'continue', 'thread apply all bt',
        ]
        command = ['/usr/bin/gdb', '-nx', '--batch', '--return-child-result',
                   '-iex', 'set debuginfod enabled off',
                   '-iex', 'set auto-load off']
        for item in commands:
            command.extend(['-ex', item])
        command.extend(['--args', str(binary), str(startup)])
        self.record = {'command': command, 'complete': False,
                       'started': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                       'scope': 'Owned synthetic application; no debugger downloads, init scripts or system setting changes'}
        self._debugger = subprocess.Popen(command, stdout=stream,
            stderr=subprocess.STDOUT, env=environment)
        self.record['debuggerPid'] = self._debugger.pid
        self._save()
        try:
            deadline = time.monotonic() + startup_timeout
            while time.monotonic() < deadline:
                if pid_file.is_file() and not pid_file.is_symlink():
                    raw = pid_file.read_text()
                    if raw.isascii() and raw.isdecimal() and 0 < len(raw) <= 12:
                        pid = int(raw)
                        identity = _identity(pid)
                        if (identity is not None and identity[0] == os.getuid()
                                and identity[1] == self._debugger.pid
                                and identity[3] == self._binary):
                            self.pid, self._identity = pid, identity
                            self.record['inferiorPid'] = pid
                            self.record['inferiorStartTime'] = identity[2]
                            self._save()
                            return
                if self._debugger.poll() is not None:
                    raise RuntimeError('Debugger exited before an owned application PID was available')
                time.sleep(.01)
            raise RuntimeError('Debugger did not provide an owned application PID before its deadline')
        except BaseException:
            self._cleanup_failed_start()
            raise

    def _save(self):
        temporary = self.receipt.with_suffix('.pending')
        temporary.write_text(json.dumps(self.record, indent=2) + '\n')
        temporary.replace(self.receipt)

    def _finish(self, code):
        if code is not None and not self.record['complete']:
            self.record.update(complete=True, debuggerExitCode=code,
                finished=datetime.datetime.now(datetime.timezone.utc).isoformat())
            self._save()
        return code

    def _signal(self, number):
        if self.pid is not None and _identity(self.pid) == self._identity:
            try:
                os.kill(self.pid, number)
            except ProcessLookupError:
                pass

    def _cleanup_failed_start(self):
        # The handshake may have failed before assigning self.pid. Only kill
        # direct children whose executable/UID/parent identity proves ownership.
        children = Path(f'/proc/{self._debugger.pid}/task/{self._debugger.pid}/children')
        if children.exists():
            for raw in children.read_text().split():
                pid = int(raw)
                identity = _identity(pid)
                if (identity is not None and identity[0] == os.getuid()
                        and identity[1] == self._debugger.pid
                        and identity[3] == self._binary):
                    try:
                        os.kill(pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
        if self._debugger.poll() is None:
            self._debugger.terminate()
        try:
            self._debugger.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self._debugger.kill()
            self._debugger.wait(timeout=3)
        self.record['startupFailed'] = True
        self._finish(self._debugger.returncode)

    def poll(self):
        return self._finish(self._debugger.poll())

    def wait(self, timeout=None):
        return self._finish(self._debugger.wait(timeout=timeout))

    def terminate(self):
        self._signal(signal.SIGTERM)

    def kill(self):
        self._signal(signal.SIGKILL)
        try:
            self.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self._debugger.kill()
            self._finish(self._debugger.wait(timeout=3))


def launch_application(binary, startup, stream, environment, *, backtrace=None):
    if backtrace is not None:
        return DebuggedApplication(binary, startup, stream, environment, backtrace)
    return subprocess.Popen([str(binary), str(startup)], stdout=stream,
                            stderr=subprocess.STDOUT, env=environment)
