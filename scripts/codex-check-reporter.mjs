// Keep fixture diagnostics visible while Node buffers a file's ordinary results.
export default async function* reporter(events) {
  for await (const { type, data } of events) {
    if (type === 'test:stderr' || type === 'test:stdout') yield data.message;
    if (type === 'test:dequeue') yield `codex-check: test-start ${data.name}\n`;
    if (type === 'test:pass' || type === 'test:fail') {
      yield `codex-check: ${type} ${data.name} duration=${data.details?.duration_ms}ms\n`;
      if (type === 'test:fail') yield `${String(data.details?.error?.stack ?? data.details?.error ?? 'failed').slice(-8192)}\n`;
    }
    if (type === 'test:diagnostic') yield `codex-check: ${data.message}\n`;
  }
}
