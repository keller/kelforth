// kelforth stage 1 — words and the dictionary
//
// New since stage 0:
//   - a real dictionary of words instead of a fixed builtin table
//   - the colon compiler:  : square dup * ;
//   - comments: ( ... ) and \ to end of line
//   - the classic stack-shuffling words: dup drop swap over rot nip tuck
//
//   node kelforth.js                 interactive REPL
//   node kelforth.js examples/x.fs   run a source file

import { readFileSync } from "node:fs";
import { createInterface } from "node:readline";

// ---------------------------------------------------------------- the stack

const stack = [];

function push(n) {
  stack.push(n);
}

function pop() {
  const n = stack.pop();
  if (n === undefined) throw new Error("stack underflow");
  return n;
}

function peek(depth) {
  const n = stack[stack.length - 1 - depth];
  if (n === undefined) throw new Error("stack underflow");
  return n;
}

// ---------------------------------------------------------------- output

const write = (s) => process.stdout.write(s);

// ------------------------------------------------------------ input source
//
// Stage 0 pre-split each line into tokens. Now words like `:` and `(` need
// to read *ahead* in the input themselves — `:` reads the name of the word
// being defined, `(` reads until the closing paren. So the input becomes a
// little object: the text lives in a closure along with a read position,
// and tokens are pulled from it on demand. (Real Forths do exactly this;
// the position variable is traditionally called >IN.)

function makeSource(text) {
  let pos = 0;
  return {
    nextToken() {
      while (pos < text.length && /\s/.test(text[pos])) pos++;
      if (pos >= text.length) return null;
      const start = pos;
      while (pos < text.length && !/\s/.test(text[pos])) pos++;
      return text.slice(start, pos);
    },
    skipUntil(delim) {
      const end = text.indexOf(delim, pos);
      pos = end === -1 ? text.length : end + delim.length;
    },
  };
}

let input; // the source currently being interpreted

// ------------------------------------------------------------ the dictionary
//
// A word is either a primitive (a JavaScript function, under `fn`) or a
// colon definition (a list of tokens the user wrote, under `body`).

const dict = new Map();

function prim(name, fn) {
  dict.set(name.toLowerCase(), { name, fn });
}

function find(name) {
  return dict.get(name.toLowerCase());
}

// ------------------------------------------------------------ the primitives

// arithmetic ( a b -- c )
prim("+", () => { const b = pop(), a = pop(); push(a + b); });
prim("-", () => { const b = pop(), a = pop(); push(a - b); });
prim("*", () => { const b = pop(), a = pop(); push(a * b); });
prim("/", () => {
  const b = pop(), a = pop();
  if (b === 0) throw new Error("division by zero");
  push(Math.trunc(a / b));
});
prim("mod", () => {
  const b = pop(), a = pop();
  if (b === 0) throw new Error("division by zero");
  push(a % b);
});
prim("negate", () => push(-pop()));

// stack shuffling — the words you use instead of variable names
prim("dup",   () => push(peek(0)));                                  // ( a -- a a )
prim("drop",  () => { pop(); });                                     // ( a -- )
prim("swap",  () => { const b = pop(), a = pop(); push(b); push(a); }); // ( a b -- b a )
prim("over",  () => push(peek(1)));                                  // ( a b -- a b a )
prim("rot",   () => { const c = pop(), b = pop(), a = pop(); push(b); push(c); push(a); }); // ( a b c -- b c a )
prim("nip",   () => { const b = pop(); pop(); push(b); });           // ( a b -- b )
prim("tuck",  () => { const b = pop(), a = pop(); push(b); push(a); push(b); }); // ( a b -- b a b )
prim("depth", () => push(stack.length));                             // ( -- n )

// output
prim(".",    () => write(pop() + " "));
prim(".s",   () => write(`<${stack.length}> ${stack.join(" ")} `));
prim("emit", () => write(String.fromCharCode(pop())));               // ( char -- )
prim("cr",   () => write("\n"));
prim("bye",  () => process.exit(0));

// comments — yes, comments are just words that eat some input!
prim("\\", () => input.skipUntil("\n"));
prim("(",  () => input.skipUntil(")"));

// ---------------------------------------------------------- the colon compiler
//
// `:` reads a name, then collects tokens up to `;` as the body. Executing a
// colon word simply interprets its saved tokens one by one. This is called
// "string threading" — the simplest possible implementation. (It also means
// words are looked up at RUN time, not definition time: a wart we fix in
// stage 2 with a real compiler.)

prim(":", () => {
  const name = input.nextToken();
  if (name === null) throw new Error(": needs a name");
  const body = [];
  for (;;) {
    const tok = input.nextToken();
    if (tok === null) throw new Error(`missing ; in definition of ${name}`);
    if (tok === ";") break;
    if (tok === "\\") { input.skipUntil("\n"); continue; }
    if (tok === "(")  { input.skipUntil(")");  continue; }
    body.push(tok);
  }
  dict.set(name.toLowerCase(), { name, body });
});

prim(";", () => { throw new Error("; outside a definition"); });

// ---------------------------------------------------------- the interpreter

function execute(word) {
  if (word.fn) {
    word.fn();
  } else {
    for (const token of word.body) interpretToken(token);
  }
}

function interpretToken(token) {
  const word = find(token);
  if (word) {
    execute(word);
  } else if (/^-?\d+$/.test(token)) {
    push(parseInt(token, 10));
  } else {
    throw new Error(`undefined word: ${token}`);
  }
}

function interpret(text) {
  input = makeSource(text);
  for (;;) {
    const token = input.nextToken();
    if (token === null) break;
    interpretToken(token);
  }
}

// ---------------------------------------------------------------- run modes

const file = process.argv[2];

if (file) {
  // The whole file is one source, so definitions may span lines.
  try {
    interpret(readFileSync(file, "utf8"));
  } catch (err) {
    console.error(`error: ${err.message}`);
    process.exit(1);
  }
} else {
  write("kelforth stage 1 — words and the dictionary. Type `bye` to quit.\n");
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  rl.on("line", (line) => {
    try {
      interpret(line);
      write(" ok\n");
    } catch (err) {
      write(`error: ${err.message}\n`);
      stack.length = 0;
    }
    rl.prompt();
  });
  rl.on("close", () => write("\n"));
  rl.prompt();
}
