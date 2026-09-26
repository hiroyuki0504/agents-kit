#!/usr/bin/env python3
"""Usage parsing + real subprocess/git handoffs. No credentials or network."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("relay", ROOT / "kit/agents_relay.py")
relay = importlib.util.module_from_spec(spec)
spec.loader.exec_module(relay)


class UsageTests(unittest.TestCase):
    def setUp(self):
        self.cfg = relay.settings(None)

    def snap(self, remaining):
        return {"available": True, "windows": {"week": relay.observation(remaining)}}

    def test_most_remaining_uses_bottleneck_and_excludes_source(self):
        a, b = self.snap(90), self.snap(70)
        a["windows"]["five_hour"] = relay.observation(20)
        self.assertEqual(relay.select_provider({"a": a, "b": b}, self.cfg, set()), "b")
        self.assertIsNone(relay.select_provider({"a": a, "b": b}, self.cfg, {"b"}))

    def test_stale_future_reset_missing_and_uninstalled_are_not_capacity(self):
        for modify in (lambda w: w.update(observed_at=time.time() - 1000),
                       lambda w: w.update(observed_at=time.time() + 1000),
                       lambda w: w.update(resets_at=time.time() - 1),
                       lambda w: w.pop("observed_at")):
            snap = self.snap(99)
            modify(snap["windows"]["week"])
            self.assertIsNone(relay.select_provider({"a": snap}, self.cfg, set()))
        self.assertIsNone(relay.select_provider({"a": {"available": True}}, self.cfg, set()))
        snap = self.snap(99)
        snap["available"] = False
        self.assertIsNone(relay.select_provider({"a": snap}, self.cfg, set()))

    def test_one_low_window_triggers_even_if_other_stale(self):
        snap = self.snap(2)
        snap["windows"]["old"] = relay.observation(80, time.time() - 1000)
        self.assertIsNone(relay.quota(snap, self.cfg))
        self.assertEqual(relay.low_reason(snap, self.cfg), "quota")

    def test_context_and_threshold_boundary(self):
        snap = self.snap(99)
        snap["context"] = relay.observation(15)
        self.assertEqual(relay.low_reason(snap, self.cfg), "context")
        self.assertIsNone(relay.select_provider({"a": self.snap(25)}, self.cfg, set()))
        self.assertEqual(relay.select_provider({"a": self.snap(25.01)}, self.cfg, set()), "a")

    def test_invalid_and_unknown_usage_is_never_zero_or_unlimited(self):
        for value in (None, True, "99", float("nan"), float("inf"), -1, 101):
            self.assertIsNone(relay.observation(value))
        with self.assertRaises(relay.RelayError):
            relay.normalized({"windows": {"a": {"remaining_percent": "99"}}})
        self.assertIsNone(relay.quota(relay.normalized({"windows": {
            "week": {"remaining_percent": 90}}}), self.cfg))

    def test_codex_bucket_selection(self):
        data = {"rateLimits": {"primary": {"usedPercent": 1}},
                "rateLimitsByLimitId": {"codex": {"primary": {"usedPercent": 80},
                    "secondary": {"usedPercent": 91}}, "spark": {"primary": {"usedPercent": 0}}}}
        self.assertEqual(relay.quota(relay.codex_usage(data), self.cfg), 9)
        self.assertIsNone(relay.quota(relay.codex_usage(data, "missing"), self.cfg))

    def test_partially_unknown_quota_never_becomes_free_capacity(self):
        for data in (relay.codex_usage({"rateLimits": {"primary": {"usedPercent": 1},
                         "secondary": {"usedPercent": None}}}),
                     relay.claude_usage({"rate_limits": {"five_hour": {"utilization": 1},
                         "seven_day": {"utilization": None}}})):
            self.assertIsNone(relay.quota(data, self.cfg))
        for data in (None, [], "bad"):
            self.assertIsNone(relay.quota(relay.codex_usage(data), self.cfg))
            self.assertIsNone(relay.quota(relay.claude_usage(data), self.cfg))

    def test_exact_codex_rollout_and_partial_lines(self):
        with tempfile.TemporaryDirectory() as tmp:
            old = os.environ.get("CODEX_HOME")
            os.environ["CODEX_HOME"] = tmp
            try:
                from datetime import datetime, timedelta, timezone
                day = datetime.now(timezone.utc) + timedelta(days=1)
                directory = Path(tmp) / "sessions" / day.strftime("%Y/%m/%d")
                directory.mkdir(parents=True)
                session = "12345678-1234-1234-1234-123456789abc"
                path = directory / ("rollout-" + session + ".jsonl")
                event = {"type":"event_msg", "payload":{"type":"token_count","info":{}}}
                path.write_text(json.dumps(event)[:-1])
                (directory / "unrelated.jsonl").write_text(json.dumps(event)+"\n")
                tail = relay.CodexTail()
                tail.session = session
                self.assertEqual(tail.read(), [])
                with path.open("a") as f: f.write("}\n")
                self.assertEqual(tail.read(), [event])
                self.assertEqual(tail.read(), [])
            finally:
                if old is None: os.environ.pop("CODEX_HOME")
                else: os.environ["CODEX_HOME"] = old

    def test_codex_context_uses_last_request_not_lifetime_total(self):
        t = relay.Telemetry({"kind": "codex"})
        t.consume({"type": "event_msg", "timestamp": time.time(), "payload": {
            "type": "token_count", "info": {"model_context_window": 1000,
                "last_token_usage": {"total_tokens": 900},
                "total_token_usage": {"total_tokens": 99999999}}}})
        self.assertAlmostEqual(t.data["context"]["remaining_percent"], 10)
        self.assertEqual(relay.low_reason(t.data, self.cfg), "context")

    def test_claude_wire_percent_and_fraction_are_distinct(self):
        s = relay.claude_usage({"rate_limits": {"five_hour": {"utilization": 20},
                               "seven_day": {"utilization": 90}}})
        self.assertEqual(relay.quota(s, self.cfg), 10)
        t = relay.Telemetry({"kind": "claude"})
        t.consume({"type": "rate_limit_event", "rate_limit_info": {
            "unifiedWindows": {"five_hour": {"utilization": .2},
                               "seven_day": {"utilization": .9}}}})
        self.assertEqual(relay.quota(t.data, self.cfg), 10)
        s = relay.claude_usage({"rate_limits": {"five_hour": {"used_percentage": 80}},
                               "context_window": {"remaining_percentage": 8}}, statusline=True)
        self.assertEqual(s["context"]["remaining_percent"], 8)
        self.assertEqual(relay.quota(s, self.cfg), 20)

    def test_claude_context_counts_cache_but_not_subagents(self):
        t = relay.Telemetry({"kind": "claude", "context_window_tokens": 1000})
        t.consume({"type": "assistant", "message": {"usage": {
            "input_tokens": 100, "cache_read_input_tokens": 800,
            "cache_creation_input_tokens": 50}, "content": []}})
        self.assertAlmostEqual(t.data["context"]["remaining_percent"], 5)
        t.consume({"type": "assistant", "parent_tool_use_id": "child", "message": {
            "usage": {"input_tokens": 1}, "content": []}})
        self.assertAlmostEqual(t.data["context"]["remaining_percent"], 5)

    def test_no_inferred_context_capacity_or_quota_from_error_text(self):
        t = relay.Telemetry({"kind": "claude"})
        t.tokens(1234)
        self.assertNotIn("context", t.data)
        t.consume({"type": "error", "message": "someone wrote rate limit in a test"})
        self.assertTrue(t.failed)
        self.assertIsNone(t.reason)

    def test_config_validation_and_no_shell_commands(self):
        for raw in ({"quota_threshold": 90}, {"poll_seconds": 0}, {"max_handoffs": 1.5},
                    {"providers": {"other": {"command": "echo hi"}}}, {"typo": 5}):
            with self.assertRaises(relay.RelayError):
                relay.settings(raw)

    def test_child_identity_removed_auth_untouched(self):
        previous = dict(os.environ)
        try:
            os.environ.update(CLAUDECODE="1", CODEX_THREAD_ID="source", OPENAI_API_KEY="test-only")
            env = relay.child_env()
            self.assertNotIn("CLAUDECODE", env)
            self.assertNotIn("CODEX_THREAD_ID", env)
            self.assertEqual(env["OPENAI_API_KEY"], "test-only")
        finally:
            os.environ.clear()
            os.environ.update(previous)


FAKE = r'''
import json,sys,time,signal,subprocess,os
from pathlib import Path
def emit(v):
    print(json.dumps(v),flush=True)
mode=sys.argv[1]
if mode == 'usage':
    emit({'windows':{'week':{'remaining_percent':float(sys.argv[2]),'observed_at':time.time()}}})
    sys.exit(0)
prompt=sys.stdin.read()
name=sys.argv[2]
Path(name+'.prompt').write_text(prompt)
Path(name+'.pid').write_text(str(os.getpid()))
with Path('launches').open('a') as f: f.write(name+'\n')
if mode in ('quota','context','wait','spawn'):
    Path('dirty.txt').write_text('saved by '+name)
    child=None
    if mode=='spawn':
        child=subprocess.Popen([sys.executable,'-c','import time; time.sleep(300)'])
        Path('child.pid').write_text(str(child.pid))
    def stop(*args):
        if child is not None:
            try: child.wait(timeout=2)
            except subprocess.TimeoutExpired:
                child.kill(); child.wait()
        Path(name+'.stopped').write_text('yes')
        sys.exit(0)
    signal.signal(signal.SIGINT,stop)
    signal.signal(signal.SIGTERM,stop)
    if mode in ('quota','context'):
        event={'type':'agents_usage','windows':{}}
        obs={'remaining_percent':5,'observed_at':time.time()}
        if mode=='quota': event['windows']['week']=obs
        else: event['context']=obs
        emit(event)
    while True: time.sleep(.1)
elif mode=='finish':
    if Path('dirty.txt').exists():
        assert Path('first.stopped').exists(), 'predecessor still running'
        assert Path('dirty.txt').read_text()=='saved by first'
        assert 'original user requirement' in prompt
    Path('finished.txt').write_text('done by '+name)
    emit({'type':'agents_result','success':True})
elif mode=='fail':
    sys.exit(2)
elif mode=='false-success':
    emit({'type':'agents_result','success':True})
    sys.exit(2)
'''

NATIVE = r'''#!/usr/bin/env python3
import sys,json,time,signal,os
from pathlib import Path
def emit(x): print(json.dumps(x),flush=True)
def stop(*args):
    Path('first.stopped').write_text('yes'); sys.exit(0)
signal.signal(signal.SIGINT,stop)
signal.signal(signal.SIGTERM,stop)
mode=sys.argv[1]
for line in sys.stdin:
    e=json.loads(line)
    if mode=='app-server':
        if e.get('id')==1: emit({'id':1,'result':{}})
        if e.get('id')==2: emit({'id':2,'result':{'rateLimitsByLimitId':{
            'codex':{'primary':{'usedPercent':20},'secondary':{'usedPercent':30}},
            'spark':{'primary':{'usedPercent':99}}}}})
        continue
    if e.get('type')=='control_request':
        sub=e['request']['subtype']
        value={}
        if sub=='get_usage': value={'rate_limits':{'five_hour':{'utilization':20},'seven_day':{'utilization':30}}}
        if sub=='get_context_usage': value={'totalTokens':950,'maxTokens':1000}
        emit({'type':'control_response','response':{'subtype':'success','request_id':e['request_id'],'response':value}})
    elif e.get('type')=='user':
        Path('dirty.txt').write_text('saved by first')
        with Path('launches').open('a') as f: f.write('first\n')
        if mode=='claude-deny':
            emit({'type':'control_request','request_id':'permission','request':{'subtype':'can_use_tool','tool_name':'Bash'}})
    elif e.get('type')=='control_response':
        assert e['response']['response']['behavior']=='deny'
        emit({'type':'result','subtype':'success','is_error':False,'permission_denials':[{'tool_name':'Bash'}]})
        break
'''


class NativeProbeTests(unittest.TestCase):
    def test_both_native_protocols_without_inference(self):
        with tempfile.TemporaryDirectory() as tmp:
            binary = Path(tmp) / "native"
            binary.write_text(NATIVE)
            binary.chmod(0o755)
            cfg = relay.settings(None)
            for kind in ("codex","claude"):
                with self.subTest(kind=kind):
                    p = {"kind":kind,"command":[str(binary),kind]}
                    self.assertEqual(relay.quota(relay.probe_native(p,Path(tmp),cfg),cfg),70)


class IntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="agents-relay-test-")
        cls.base = Path(cls.temp.name)
        cls.repo = cls.base / "repo"
        cls.fake = cls.base / "fake.py"
        cls.fake.write_text(FAKE)
        cls.native = cls.base / "native"
        cls.native.write_text(NATIVE)
        cls.native.chmod(0o755)
        cls.env = dict(os.environ, GIT_AUTHOR_NAME="relay-test", GIT_AUTHOR_EMAIL="relay@example.invalid",
                       GIT_COMMITTER_NAME="relay-test", GIT_COMMITTER_EMAIL="relay@example.invalid")
        cls.env.pop("AGENTS_RELAY_ACTIVE", None)
        cls.shell(["git", "init", "--bare", "-b", "main", str(cls.base / "origin.git")], cls.base)
        cls.shell(["git", "clone", str(cls.base / "origin.git"), str(cls.repo)], cls.base)
        (cls.repo / "README.md").write_text("seed\n")
        cls.shell(["git", "add", "README.md"], cls.repo)
        cls.shell(["git", "commit", "-m", "seed"], cls.repo)
        cls.shell(["git", "push", "origin", "main"], cls.repo)
        cls.shell([str(ROOT / "install.sh"), str(cls.repo)], cls.base)
        cls.ag = cls.repo / ".agents/bin/agents"

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    @classmethod
    def shell(cls, args, cwd, expected=0, timeout=30):
        result = subprocess.run([str(a) for a in args], cwd=str(cwd), env=cls.env,
                                capture_output=True, text=True, timeout=timeout)
        if expected is not None and result.returncode != expected:
            raise AssertionError("%s\nrc=%s\n%s\n%s" % (args,result.returncode,result.stdout,result.stderr))
        return result

    def setUp(self):
        slug = self.id().split(".")[-1].replace("_", "-")[:38]
        self.configure({"first": ("quota", 90), "second": ("finish", 80)})
        d = self.shell([self.ag,"directive","original user requirement", "--json"], self.repo)
        seq = json.loads(d.stdout)["directive"]
        self.shell([self.ag,"start",slug,"--directive",seq,"--paths",slug+"/**","--intent",slug],self.repo)
        self.wt = next((self.repo / ".worktrees").glob(slug+"-*"))
        gitdir = self.shell(["git","rev-parse","--absolute-git-dir"],self.wt).stdout.strip()
        self.state = Path(gitdir) / "agents-relay"

    def configure(self, modes, **kwargs):
        providers = {name: {"kind":"custom", "command":[sys.executable,str(self.fake),mode,name],
                            "usage_command":[sys.executable,str(self.fake),"usage",str(remaining)]}
                     for name,(mode,remaining) in modes.items()}
        cfg = {"test_cmd":"true","pr":"off","relay":dict(providers=providers,poll_seconds=.2,
                    probe_timeout_seconds=2,stop_timeout_seconds=.3,**kwargs)}
        (self.repo / ".agents/config.json").write_text(json.dumps(cfg))

    def run_cli(self, *args, expected=0):
        return self.shell([self.ag,*args],self.wt,expected)

    def test_quota_handoff_preserves_dirty_and_checkpoint(self):
        self.run_cli("checkpoint","--text","Tests passed; continue with the remaining validation")
        self.run_cli("run","--provider","first")
        self.assertEqual((self.wt/"launches").read_text().splitlines(),["first","second"])
        self.assertTrue((self.wt/"dirty.txt").exists())
        self.assertIn("Tests passed",(self.wt/"second.prompt").read_text())
        self.assertEqual(json.loads((self.state/"run.json").read_text())["status"],"returned")
        tracked = self.shell(["git","ls-files"],self.wt).stdout
        self.assertNotIn("handoff.json",tracked)
        self.assertFalse((self.repo/".agents/bin/__pycache__").exists())

    def test_context_handoff_with_healthy_quota(self):
        self.configure({"first":("context",90),"second":("finish",80)})
        self.run_cli("run","--provider","first")
        data=json.loads((self.state/"handoff.json").read_text())
        self.assertEqual(data["reason"],"context")

    def test_native_claude_context_control_handoff(self):
        path=self.repo/".agents/config.json"
        cfg=json.loads(path.read_text())
        cfg["relay"]["providers"]["first"]={"kind":"claude","command":[str(self.native),"claude"]}
        path.write_text(json.dumps(cfg))
        self.run_cli("run","--provider","first")
        self.assertEqual((self.wt/"launches").read_text().splitlines(),["first","second"])
        self.assertEqual(json.loads((self.state/"handoff.json").read_text())["reason"],"context")

    def test_native_permission_request_denied_and_not_success(self):
        path=self.repo/".agents/config.json"
        cfg=json.loads(path.read_text())
        cfg["relay"]["providers"]["first"]={"kind":"claude","command":[str(self.native),"claude-deny"]}
        path.write_text(json.dumps(cfg))
        self.run_cli("run","--provider","first",expected=6)
        self.assertEqual((self.wt/"launches").read_text().splitlines(),["first"])

    def test_no_capacity_pauses_without_launching_low_target(self):
        self.configure({"first":("quota",90),"second":("finish",5)})
        self.run_cli("run","--provider","first",expected=9)
        self.assertEqual((self.wt/"launches").read_text().splitlines(),["first"])
        self.assertTrue((self.state/"handoff.json").exists())
        self.assertEqual(json.loads((self.state/"run.json").read_text())["status"],"paused")

    def test_restart_keeps_original_task_and_saved_work(self):
        prompt = self.base / "resume-task.txt"
        prompt.write_text("special original task must survive restart")
        self.configure({"first":("quota",90),"second":("finish",5)})
        self.run_cli("run","--provider","first","--prompt-file",str(prompt),expected=9)
        self.configure({"second":("finish",80)})
        self.run_cli("run")
        self.assertIn("special original task must survive restart",(self.wt/"second.prompt").read_text())

    def test_claim_loss_stops_worker_before_successor(self):
        self.configure({"first":("wait",90),"second":("finish",80)})
        proc = subprocess.Popen([str(self.ag),"run","--provider","first"],cwd=self.wt,env=self.env,
                                stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        try:
            deadline=time.monotonic()+10
            while not (self.wt/"first.pid").exists() and time.monotonic()<deadline:
                time.sleep(.05)
            self.assertTrue((self.wt/"first.pid").exists())
            self.run_cli("release")
            out,err=proc.communicate(timeout=10)
            self.assertEqual(proc.returncode,8,(out,err))
            self.assertTrue((self.wt/"first.stopped").exists())
            self.assertFalse((self.wt/"finished.txt").exists())
        finally:
            if proc.poll() is None: proc.terminate();proc.wait(timeout=5)
            proc.stdout.close();proc.stderr.close()

    def test_no_ping_pong(self):
        self.configure({"first":("quota",90),"second":("context",80)})
        self.run_cli("run","--provider","first",expected=9)
        self.assertEqual((self.wt/"launches").read_text().splitlines(),["first","second"])

    def test_limit_handoffs(self):
        self.configure({"first":("quota",90),"second":("context",80),"third":("finish",70)},max_handoffs=1)
        self.run_cli("run","--provider","first",expected=9)
        self.assertEqual((self.wt/"launches").read_text().splitlines(),["first","second"])

    def test_existing_ai_handoff_returns_stop_signal(self):
        self.run_cli("handoff","--from","first","--context-remaining","5",expected=9)
        self.assertEqual((self.wt/"launches").read_text().splitlines(),["second"])

    def test_healthy_does_not_handoff(self):
        self.run_cli("handoff","--from","first","--context-remaining","80")
        self.assertFalse((self.wt/"launches").exists())

    def test_error_is_not_completion_or_capacity_failure(self):
        for mode in ("fail", "false-success"):
            with self.subTest(mode=mode):
                self.configure({"first":(mode,90),"second":("finish",80)})
                self.run_cli("run","--provider","first",expected=6)
                self.assertFalse((self.wt/"finished.txt").exists())
                self.assertEqual(json.loads((self.state/"run.json").read_text())["status"],"failed")

    def test_repo_root_rejected(self):
        self.shell([self.ag,"run","--provider","first"],self.repo,expected=3)

    def test_git_operation_in_progress_rejected(self):
        lock = self.state.parent/"index.lock"
        lock.write_text("in progress")
        try:
            self.run_cli("run","--provider","first",expected=3)
            self.assertFalse((self.wt/"launches").exists())
        finally:
            lock.unlink()

    def test_lock_and_sigterm_stop_all_children(self):
        self.configure({"first":("spawn",90)})
        proc = subprocess.Popen([str(self.ag),"run","--provider","first"],cwd=self.wt,env=self.env,
                                stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        try:
            deadline=time.monotonic()+10
            while not (self.wt/"child.pid").exists() and time.monotonic()<deadline:
                time.sleep(.05)
            self.assertTrue((self.wt/"child.pid").exists())
            self.run_cli("run","--provider","first",expected=4)
            proc.terminate()
            out,err=proc.communicate(timeout=10)
            self.assertEqual(proc.returncode,143,(out,err))
            self.assertTrue((self.wt/"first.stopped").exists())
            child=int((self.wt/"child.pid").read_text())
            with self.assertRaises(ProcessLookupError): os.kill(child,0)
            self.assertNotEqual(json.loads((self.state/"run.json").read_text())["status"],"running")
        finally:
            if proc.poll() is None:
                proc.kill();proc.wait()
            proc.stdout.close();proc.stderr.close()


if __name__ == "__main__":
    unittest.main(verbosity=2)
