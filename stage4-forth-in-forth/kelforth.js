// kelforth stage 4 — Forth in Forth
//
// The payoff stage. Two big changes since stage 3:
//
//   1. ONE MEMORY. Compiled code now lives in the same cell array as data,
//      as "threaded code": each cell of a definition is an execution token
//      (xt) — an index into the word table — or an inline operand. The
//      dictionary pointer `here` allocates code and data alike.
//
//   2. A MINIMAL KERNEL. This file keeps only what Forth cannot say about
//      itself: the stacks, the memory, the outer/inner interpreters, and
//      ~50 primitives. Everything else — including if/else/then and the
//      loops! — is defined IN FORTH, in core.fs, loaded at startup.
//      Read core.fs. That's the point of this stage.
//
//   node kelforth.js                 interactive REPL
//   node kelforth.js examples/x.fs   run a source file

import { readFileSync } from "node:fs";
import { createInterface } from "node:readline";

// ---------------------------------------------------------------- the stacks

const stack = [];   // data stack
const rstack = [];  // return stack (threaded-code return addresses)

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

function rpop() {
  const n = rstack.pop();
  if (n === undefined) throw new Error("return stack underflow");
  return n;
}

// ---------------------------------------------------------------- the memory
//
// Code AND data live here now. `here` allocates both.

const MEM_SIZE = 65536;
const mem = new Array(MEM_SIZE).fill(0);
let here = 0;

function checkAddr(addr) {
  if (!Number.isInteger(addr) || addr < 0 || addr >= MEM_SIZE) {
    throw new Error(`invalid memory address: ${addr}`);
  }
  return addr;
}

function compile(x) {
  mem[checkAddr(here)] = x;
  here++;
}

// ---------------------------------------------------------------- output

const write = (s) => process.stdout.write(s);

// ------------------------------------------------------------ input source

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
    parse(delim) {
      if (text[pos] === " ") pos++;
      const end = text.indexOf(delim, pos);
      const s = text.slice(pos, end === -1 ? text.length : end);
      pos = end === -1 ? text.length : end + 1;
      return s;
    },
  };
}

let input;

// ------------------------------------------------------------ the dictionary
//
// A word is a table entry; an EXECUTION TOKEN (xt) is its index. A compiled
// definition is a run of cells in `mem`, each an xt (or an inline operand
// following words like `lit` and `branch`). This is "threaded code".
//
// A word is a plain object:
//   { name, immediate, prim }   primitive: a JavaScript function
//   { name, immediate, addr }   colon word: address of its threaded code

const words = [];
const dict = new Map(); // name -> xt

let latest; // most recently defined word (for `immediate`)

function defineWord(w) {
  words.push(w);
  const xt = words.length - 1;
  dict.set(w.name.toLowerCase(), xt);
  latest = w;
  return xt;
}

function prim(name, fn, immediate = false) {
  return defineWord({ name, immediate, prim: fn });
}

function find(name) {
  return dict.get(name.toLowerCase());
}

function findOrThrow(name, who) {
  if (name === null) throw new Error(`${who} needs a word name`);
  const xt = find(name);
  if (xt === undefined) throw new Error(`${who}: undefined word ${name}`);
  return xt;
}

// ---------------------------------------------------------- inner interpreter
//
// `ip` walks threaded code in mem. Executing a colon word saves ip on the
// return stack and jumps; `exit` (compiled by `;`) pops it back. A sentinel
// of -1 marks "return to JavaScript".

let ip = -1;

function executeXt(xt) {
  const w = words[xt];
  if (!w) throw new Error(`bad execution token: ${xt}`);
  if (w.prim) {
    w.prim();
    return;
  }
  const savedIp = ip;
  rstack.push(-1);
  ip = w.addr;
  while (ip !== -1) {
    const x = mem[checkAddr(ip++)];
    const t = words[x];
    if (!t) throw new Error(`bad execution token ${x} in compiled code`);
    if (t.prim) {
      t.prim();
    } else {
      rstack.push(ip);
      ip = t.addr;
    }
  }
  ip = savedIp;
}

// ------------------------------------------------------------ compiler state

let state = 0; // 0 = interpreting, 1 = compiling
let pendingXt = -1;
let pendingName = "";

function mustBeCompiling(name) {
  if (state !== 1) throw new Error(`${name} is compile-only (use it inside a definition)`);
}

// ------------------------------------------------------- runtime primitives
//
// These exist to BE COMPILED — they read operands inline from the threaded
// code via ip. core.fs's control-flow words compile them with ['] ... ,

prim("lit",     () => push(mem[checkAddr(ip++)]));                       // push next cell
prim("branch",  () => { ip = checkAddr(mem[ip]); });                     // jump
prim("0branch", () => { const t = mem[ip]; if (pop() === 0) ip = checkAddr(t); else ip++; });
prim("exit",    () => { ip = rpop(); });                                 // return

const XT_LIT = find("lit");
const XT_EXIT = find("exit");

// ------------------------------------------------------------ the primitives

// stack
prim("dup",   () => push(peek(0)));
prim("drop",  () => { pop(); });
prim("swap",  () => { const b = pop(), a = pop(); push(b); push(a); });
prim("over",  () => push(peek(1)));
prim("rot",   () => { const c = pop(), b = pop(), a = pop(); push(b); push(c); push(a); });
prim("depth", () => push(stack.length));

// return stack (use with care: it's the actual return stack!)
prim(">r", () => rstack.push(pop()));
prim("r>", () => push(rpop()));
prim("r@", () => {
  const n = rstack[rstack.length - 1];
  if (n === undefined) throw new Error("return stack underflow");
  push(n);
});

// arithmetic
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

// comparison & logic (the rest are defined in core.fs)
prim("=",  () => { const b = pop(), a = pop(); push(a === b ? -1 : 0); });
prim("<",  () => { const b = pop(), a = pop(); push(a < b ? -1 : 0); });
prim(">",  () => { const b = pop(), a = pop(); push(a > b ? -1 : 0); });
prim("0=", () => push(pop() === 0 ? -1 : 0));
prim("and",    () => { const b = pop(), a = pop(); push(a & b); });
prim("or",     () => { const b = pop(), a = pop(); push(a | b); });
prim("xor",    () => { const b = pop(), a = pop(); push(a ^ b); });
prim("invert", () => push(~pop()));

// memory
prim("here",  () => push(here));
prim("allot", () => { here += pop(); });
prim(",",     () => compile(pop()));
prim("@",     () => push(mem[checkAddr(pop())]));
prim("!",     () => { const addr = checkAddr(pop()); mem[addr] = pop(); });

const XT_COMMA = find(",");

// I/O
prim(".",    () => write(pop() + " "));
prim(".s",   () => write(`<${stack.length}> ${stack.join(" ")} `));
prim("emit", () => write(String.fromCharCode(pop())));
prim("cr",   () => write("\n"));
prim("bye",  () => process.exit(0));
prim("words", () => { write(words.map((w) => w.name).join(" ")); write("\n"); });

// comments
prim("\\", () => input.skipUntil("\n"), true);
prim("(",  () => input.skipUntil(")"), true);

// counted-loop runtime (do/loop themselves are defined in core.fs!)
const loopStack = [];

prim("(do)", () => {
  const index = pop(), limit = pop();
  loopStack.push({ index, limit });
});
prim("(loop)", () => {
  const frame = loopStack[loopStack.length - 1];
  if (!frame) throw new Error("loop outside do");
  frame.index++;
  push(frame.index >= frame.limit ? -1 : 0);
});
prim("(unloop)", () => { loopStack.pop(); });
prim("i", () => {
  const frame = loopStack[loopStack.length - 1];
  if (!frame) throw new Error("i outside do..loop");
  push(frame.index);
});
prim("j", () => {
  const frame = loopStack[loopStack.length - 2];
  if (!frame) throw new Error("j needs a nested do..loop");
  push(frame.index);
});

// ---------------------------------------------------------- the colon compiler

prim(":", () => {
  if (state === 1) throw new Error("nested : not allowed");
  const name = input.nextToken();
  if (name === null) throw new Error(": needs a name");
  // The word exists but is NOT in the dictionary yet ("hidden"): references
  // to its own name inside the body still find the OLD definition.
  words.push({ name, immediate: false, addr: here });
  pendingXt = words.length - 1;
  pendingName = name;
  latest = words[pendingXt];
  state = 1;
});

prim(";", () => {
  mustBeCompiling(";");
  compile(XT_EXIT);
  dict.set(pendingName.toLowerCase(), pendingXt); // now it becomes findable
  state = 0;
}, true);

prim("immediate", () => { latest.immediate = true; });

prim("[", () => { state = 0; }, true); // drop to interpret state mid-definition
prim("]", () => { state = 1; });       // and back

prim("literal", () => {                // ( n -- ) compile a push-n
  mustBeCompiling("literal");
  compile(XT_LIT);
  compile(pop());
}, true);

// ' and ['] turn a name into an execution token; execute runs one.
// These give core.fs its hands: ['] 0branch , compiles a branch primitive.
prim("'", () => push(findOrThrow(input.nextToken(), "'")));

prim("[']", () => {
  mustBeCompiling("[']");
  const xt = findOrThrow(input.nextToken(), "[']");
  compile(XT_LIT);
  compile(xt);
}, true);

prim("execute", () => executeXt(pop()));

prim("postpone", () => {
  mustBeCompiling("postpone");
  const xt = findOrThrow(input.nextToken(), "postpone");
  if (words[xt].immediate) {
    compile(xt);                    // immediate word: compile a call to it
  } else {
    compile(XT_LIT);                // ordinary word: compile code that will
    compile(xt);                    // compile a call to it (meta!)
    compile(XT_COMMA);
  }
}, true);

// defining words for data (variable is built from create in core.fs)
prim("create", () => {
  const name = input.nextToken();
  if (name === null) throw new Error("create needs a name");
  const addr = here;
  prim(name, () => push(addr));
});

prim("constant", () => {
  const name = input.nextToken();
  if (name === null) throw new Error("constant needs a name");
  const value = pop();
  prim(name, () => push(value));
});

// ." — still a primitive: it needs raw access to the input to grab the
// string, and inline string storage in the threaded code.
const XT_DOTQ = prim('(.")', () => {
  let len = mem[checkAddr(ip++)];
  let s = "";
  while (len-- > 0) s += String.fromCharCode(mem[checkAddr(ip++)]);
  write(s);
});

prim('."', () => {
  const text = input.parse('"');
  if (state === 1) {
    compile(XT_DOTQ);
    compile(text.length);
    for (const ch of text) compile(ch.charCodeAt(0));
  } else {
    write(text);
  }
}, true);

// ---------------------------------------------------------- the interpreter

function interpret(text) {
  input = makeSource(text);
  for (;;) {
    const token = input.nextToken();
    if (token === null) break;
    const xt = find(token);
    if (xt !== undefined) {
      if (state === 1 && !words[xt].immediate) {
        compile(xt);
      } else {
        executeXt(xt);
      }
    } else if (/^-?\d+$/.test(token)) {
      const n = parseInt(token, 10);
      if (state === 1) {
        compile(XT_LIT);
        compile(n);
      } else {
        push(n);
      }
    } else {
      state = 0;
      throw new Error(`undefined word: ${token}`);
    }
  }
}

// ------------------------------------------------------------- boot core.fs
//
// The rest of the language defines itself. If this file errors, the Forth
// is broken at birth — so we fail loudly.

const coreSource = readFileSync(new URL("./core.fs", import.meta.url), "utf8");
try {
  interpret(coreSource);
} catch (err) {
  console.error(`error while loading core.fs: ${err.message}`);
  process.exit(1);
}

// ---------------------------------------------------------------- run modes

const file = process.argv[2];

if (file) {
  try {
    interpret(readFileSync(file, "utf8"));
  } catch (err) {
    console.error(`error: ${err.message}`);
    process.exit(1);
  }
} else {
  write("kelforth stage 4 — Forth in Forth. Type `bye` to quit, `words` to look around.\n");
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  rl.on("line", (line) => {
    try {
      interpret(line);
      write(state === 1 ? " compiled\n" : " ok\n");
    } catch (err) {
      write(`error: ${err.message}\n`);
      stack.length = 0;
      rstack.length = 0;
      loopStack.length = 0;
      ip = -1;
    }
    rl.prompt();
  });
  rl.on("close", () => write("\n"));
  rl.prompt();
}
