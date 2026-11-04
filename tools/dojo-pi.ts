// Xyntetik Dojo extension for pi.
// Registers the local Runner server as the "runner" provider and reports the
// session state (idle, running, prompt) to the supervisor bus.
// Load it with: pi -e ~/.dojo/dojo-pi.ts --provider runner

const RUNNER_URL = process.env.DOJO_RUNNER_URL || "http://127.0.0.1:8080/v1";

async function runnerModels(): Promise<any[]> {
  try {
    const res = await fetch(`${RUNNER_URL}/models`, { signal: AbortSignal.timeout(3000) });
    const body: any = await res.json();
    return (body?.data ?? []).filter((m: any) => typeof m?.id === "string" && m.id.length > 0);
  } catch {
    return [];
  }
}

const DEFAULT_CONTEXT = 32768;
const MAX_OUTPUT = 16384;

/// The context the server runs at, when its model list does not say: llama.cpp reports it on /props
/// (default_generation_settings.n_ctx), one level above /v1. Nothing found: 0.
async function servedContext(): Promise<number> {
  try {
    const root = RUNNER_URL.replace(/\/v1\/?$/, "");
    const res = await fetch(`${root}/props`, { signal: AbortSignal.timeout(3000) });
    const body: any = await res.json();
    const n = Number(body?.default_generation_settings?.n_ctx ?? 0);
    return Number.isFinite(n) && n > 0 ? n : 0;
  } catch {
    return 0;
  }
}

function positive(...values: unknown[]): number {
  for (const v of values) {
    const n = Number(v);
    if (Number.isFinite(n) && n > 0) return n;
  }
  return 0;
}

/// The context window and output limit pi is told for a served model. The server's own figures first
/// (Runner's context_window, the OpenAI-style context_length), then what the server runs at, then the
/// model's trained context (llama.cpp's meta.n_ctx_train), then the old default. An output limit the
/// server does not state is a quarter of the context, up to 16k: a 262k agent context gets room to write,
/// a 16k one keeps room to read.
export function modelLimits(m: any, served: number): { contextWindow: number; maxTokens: number } {
  const contextWindow = positive(m?.context_window, m?.context_length, served, m?.meta?.n_ctx_train) || DEFAULT_CONTEXT;
  const maxTokens = positive(m?.max_tokens) || Math.min(MAX_OUTPUT, Math.floor(contextWindow / 4));
  return { contextWindow, maxTokens };
}

function report(event: string, extra: Record<string, unknown> = {}): void {
  const token = process.env.DOJO_TOKEN;
  if (!token) return;
  const port = process.env.DOJO_PORT || "7788";
  fetch(`http://127.0.0.1:${port}/hook`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Dojo-Token": token },
    body: JSON.stringify({ hook_event_name: event, ...extra }),
    signal: AbortSignal.timeout(2000),
  }).catch(() => {});
}

export default async function (pi: any) {
  let installedEditorFactory: any;

  async function observeSubmissions(ctx: any) {
    if (!ctx?.hasUI || !ctx.ui?.setEditorComponent) return;
    const previous = ctx.ui.getEditorComponent?.();
    if (installedEditorFactory && previous === installedEditorFactory) return;
    let create = previous;
    if (!create) {
      const { CustomEditor } = await import("@earendil-works/pi-coding-agent");
      create = (tui: any, theme: any, keys: any) => new CustomEditor(tui, theme, keys);
    }
    installedEditorFactory = (tui: any, theme: any, keys: any) => {
      const editor = create(tui, theme, keys);
      let submit = editor.onSubmit;
      // Pi installs its callback after the factory returns. Observe that callback without replacing
      // its command dispatch or an existing custom editor. Autocomplete does not call onSubmit.
      const observed = (text: string) => {
        try {
          return submit?.call(editor, text);
        } finally {
          // Startup may restore the text instead of accepting it.
          if (editor.getText() === "") report("UserInputSubmitted");
        }
      };
      Object.defineProperty(editor, "onSubmit", {
        configurable: true,
        get: () => observed,
        set: (handler) => { submit = handler; },
      });
      return editor;
    };
    ctx.ui.setEditorComponent(installedEditorFactory);
  }

  const models = await runnerModels();
  // One question to the server about its context, only when its model list leaves it out.
  const served = models.some((m) => !positive(m.context_window, m.context_length)) ? await servedContext() : 0;
  if (models.length > 0) {
    pi.registerProvider("runner", {
      baseUrl: RUNNER_URL,
      apiKey: "runner",
      api: "openai-completions",
      compat: { supportsDeveloperRole: false, supportsReasoningEffort: false },
      models: models.map((m) => ({
        id: m.id,
        name: m.id,
        reasoning: false,
        input: ["text"],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        ...modelLimits(m, served),
      })),
    });
  }
  pi.on("session_start", async (_event: any, ctx: any) => {
    await observeSubmissions(ctx);
    report("SessionStart", { model: ctx?.model?.id ?? "" });
    if (models.length === 0) {
      ctx?.ui?.notify?.(`Runner is not answering at ${RUNNER_URL}. Start it with: runner -m model.gguf --serve`, "warning");
    }
  });
  pi.on("agent_start", async () => report("UserPromptSubmit"));
  pi.on("agent_settled", async () => report("Stop"));
  pi.on("ui_prompt_start", async () => report("PermissionRequest"));
  pi.on("ui_prompt_end", async () => report("PostToolUse"));
}
