#!/usr/bin/python3
"""Offline Docker substitute. Never invokes Docker, credentials, or provider APIs."""
import contextlib
import io
import json
import pathlib
import sys
import time
from unittest.mock import patch

root = pathlib.Path(__file__).parent
args = sys.argv[1:]
with (root / 'calls.jsonl').open('a') as log:
    log.write(json.dumps(args) + '\n')
if '--confirmed-reset' in args or '--models' in args:
    raise SystemExit('Unexpected operation: simulation permits usage reads only')
provider = args[-1]
assert provider in ('gptmock', 'claude')
assert 'simulation-only' in args
scenario = json.loads((root / 'scenario.json').read_text())
module = {'__name__': 'offline_collector'}
exec(compile(sys.stdin.read(), '<bundled-collector>', 'exec'), module)
now = time.time()
snapshot = dict(provider=provider, accountKey='synthetic-account', plan='Simulation', capturedAt=now,
    windows=[dict(id='weekly', title='Weekly window', scope='All models', usedPercent=42, resetsAt=now+3600)],
    extra=None, resets=dict(state='available', message='Synthetic inventory', items=[dict(id='fixture', title='Full reset',
        scope='Weekly', count=1, expiresAt=now+3600, usableNow=True, canReview=True, providerGrantID='fake',
        confirmationBinding='fake', availabilityMessage='Ready to use — synthetic data only.')]), offers=[], models=[], warnings=[])

def forbidden(*args, **kwargs):
    raise AssertionError('Network, credentials and resets are forbidden in this simulation')

for name in ['request', 'post_reset', 'post_gpt_reset', 'gpt_headers', 'claude_headers', 'submit_once']:
    module[name] = forbidden
module['detect_runtime_version'] = lambda _: scenario['version']
if scenario['status'] == 'unsupported':
    module['UNSUPPORTED_RUNTIMES'][provider][scenario['version']] = 'Synthetic incompatible runtime.'
adapter = module['ADAPTERS'][module['READ_ONLY_FALLBACKS'][provider]]
with patch.object(adapter, 'collect', return_value=snapshot, side_effect=module['FetchError'](scenario['error'], scenario.get('retryAfter')) if scenario.get('error') else None), patch.object(adapter, 'redeem', side_effect=forbidden):
    sys.argv = ['collector.py', provider]
    module['main']()
