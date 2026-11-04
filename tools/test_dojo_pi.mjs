// The editor clears on actual submissions, including commands handled before pi's input event.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import dojo, { modelLimits } from './dojo-pi.ts';

class Editor {
  text = '';
  onSubmit;
  getText() { return this.text; }
  setText(text) { this.text = text; }
  submit() {
    const text = this.text;
    this.text = '';
    return this.onSubmit?.(text);
  }
}

test('reports actual editor submissions, including local commands, once', async () => {
  const originalFetch = globalThis.fetch;
  const originalToken = process.env.DOJO_TOKEN;
  process.env.DOJO_TOKEN = 'test-token';
  const requests = [], handlers = new Map();
  globalThis.fetch = async (url, options) => {
    if (url.endsWith('/models')) return { json: async () => ({ data: [] }) };
    requests.push(JSON.parse(options.body));
    return {};
  };
  try {
    await dojo({ on: (name, handler) => handlers.set(name, handler) });
    let factory = () => new Editor(), editor;
    const ui = {
      getEditorComponent: () => factory,
      setEditorComponent: (next) => {
        factory = next;
        editor = factory({}, {}, {});
        // Pi assigns its handler AFTER invoking the editor factory.
        editor.onSubmit = function (text) {
          assert.equal(this, editor, 'preserve the callback receiver');
          if (text === 'startup') editor.setText(text);
        };
      },
      notify() {},
    };
    const ctx = { hasUI: true, ui };
    await handlers.get('session_start')({}, ctx);
    assert.ok(editor, 'install a submission observer on the actual editor');
    requests.length = 0;
    editor.setText('/session');
    await editor.submit();
    assert.deepEqual(requests.map(r => r.hook_event_name), ['UserInputSubmitted']);
    requests.length = 0;
    editor.setText('filename completion'); // accepting a completion does not call onSubmit
    assert.equal(requests.length, 0);
    editor.setText('startup');
    await editor.submit();
    assert.equal(requests.length, 0, 'startup can restore the unsent text');
    editor.setText('prompt');
    await editor.submit();
    await handlers.get('agent_start')({}, ctx);
    assert.deepEqual(requests.map(r => r.hook_event_name), ['UserInputSubmitted', 'UserPromptSubmit']);
    const installed = factory;
    await handlers.get('session_start')({}, ctx);
    assert.equal(factory, installed, 'do not stack wrappers on session changes');
  } finally {
    globalThis.fetch = originalFetch;
    if (originalToken === undefined) delete process.env.DOJO_TOKEN;
    else process.env.DOJO_TOKEN = originalToken;
  }
});

test('a served model gets the context the server runs at, not the old default', async () => {
  // Runner's model list (after its context_window field) is taken as it is.
  assert.deepEqual(modelLimits({ id: 'a', context_window: 16384 }, 0), { contextWindow: 16384, maxTokens: 4096 });
  // llama.cpp lists no context: the server's /props answer wins over the trained context.
  assert.deepEqual(modelLimits({ id: 'b', meta: { n_ctx_train: 262144 } }, 131072), { contextWindow: 131072, maxTokens: 16384 });
  // No /props answer: the trained context; nothing at all: the old default.
  assert.deepEqual(modelLimits({ id: 'c', meta: { n_ctx_train: 262144 } }, 0), { contextWindow: 262144, maxTokens: 16384 });
  assert.deepEqual(modelLimits({ id: 'd' }, 0), { contextWindow: 32768, maxTokens: 8192 });
  // A stated output limit is kept.
  assert.equal(modelLimits({ id: 'e', context_length: 8192, max_tokens: 1024 }, 0).maxTokens, 1024);

  // The extension asks /props once, only when the list leaves the context out, and registers what it found.
  const originalFetch = globalThis.fetch;
  const urls = [];
  globalThis.fetch = async (url) => {
    urls.push(String(url));
    if (String(url).endsWith('/v1/models')) return { json: async () => ({ data: [{ id: 'kolibri' }, { id: 'other' }] }) };
    if (String(url).endsWith('/props')) return { json: async () => ({ default_generation_settings: { n_ctx: 262144 } }) };
    return {};
  };
  try {
    let registered;
    await dojo({ on() {}, registerProvider: (_name, provider) => { registered = provider; } });
    assert.equal(urls.filter(u => u.endsWith('/props')).length, 1, 'one /props call for the whole list');
    assert.ok(urls.some(u => u.endsWith('8080/props')), '/props sits above /v1');
    assert.deepEqual(registered.models.map(m => [m.contextWindow, m.maxTokens]), [[262144, 16384], [262144, 16384]]);
  } finally {
    globalThis.fetch = originalFetch;
  }
});
