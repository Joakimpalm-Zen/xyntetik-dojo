// The editor clears on actual submissions, including commands handled before pi's input event.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import dojo from './dojo-pi.ts';

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
