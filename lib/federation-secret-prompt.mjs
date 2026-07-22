/**
 * Reads a secret without writing its characters to a TTY. Piped input has no
 * terminal echo to suppress, so it is read as an ordinary first line.
 */
export async function readSecret({ input, output, prompt }) {
  output.write(prompt);
  if (!input.isTTY) {
    let line = '';
    for await (const chunk of input) {
      line += chunk.toString();
      const newline = line.search(/[\r\n]/);
      if (newline !== -1) return line.slice(0, newline).trim();
    }
    return line.trim();
  }

  return new Promise((resolve, reject) => {
    let value = '';
    const wasRaw = input.isRaw;
    input.setRawMode(true);
    input.resume();
    const finish = (result, error) => {
      input.off('data', onData);
      input.setRawMode(wasRaw);
      output.write('\n');
      if (error) reject(error);
      else resolve(result.trim());
    };
    const onData = (chunk) => {
      for (const character of chunk.toString('utf8')) {
        if (character === '\u0003') return finish('', new Error('secret entry cancelled'));
        if (character === '\r' || character === '\n') return finish(value);
        if (character === '\u007f' || character === '\b') value = value.slice(0, -1);
        else value += character;
      }
    };
    input.on('data', onData);
  });
}
