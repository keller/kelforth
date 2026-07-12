// kelforth stage 5 — the playground
//
// New since stage 4:
//   - create ... does>   defining words defined IN FORTH (constant moved
//     out of the kernel and into core.fs where it belongs)
//   - strings:  s" ... " and type ;  char and [char]
//   - recurse, pick, and +loop's runtime
//
// The language is now comfortable enough to just WRITE PROGRAMS in.
// See examples/ and EXERCISES.md.
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
//   { name, immediate, prim }       primitive: a JavaScript function
//   { name, immediate, addr }       colon word: address of its threaded code
//   { name, immediate, dataAddr }   created word: address of its data field
//                                   (+ optional doesAddr: does> behavior)

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

// What happens when a word runs, by kind:
//   primitive          call the JavaScript function
//   created (no does>) push its data address
//   created + does>    push its data address, then run the does> code
//   colon word         save ip, jump into its threaded code
function invoke(w) {
  if (w.prim) {
    w.prim();
  } else if (w.dataAddr !== undefined) {
    push(w.dataAddr);
    if (w.doesAddr !== undefined) {
      rstack.push(ip);
      ip = w.doesAddr;
    }
  } else {
    rstack.push(ip);
    ip = w.addr;
  }
}

function executeXt(xt) {
  const w = words[xt];
  if (!w) throw new Error(`bad execution token: ${xt}`);
  if (w.prim) {
    w.prim();
    return;
  }
  if (w.dataAddr !== undefined && w.doesAddr === undefined) {
    push(w.dataAddr);
    return;
  }
  const savedIp = ip;
  rstack.push(-1);
  if (w.dataAddr !== undefined) {
    push(w.dataAddr);
    ip = w.doesAddr;
  } else {
    ip = w.addr;
  }
  while (ip !== -1) {
    const x = mem[checkAddr(ip++)];
    const t = words[x];
    if (!t) throw new Error(`bad execution token ${x} in compiled code`);
    invoke(t);
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
prim("(+loop)", () => {
  const frame = loopStack[loopStack.length - 1];
  if (!frame) throw new Error("+loop outside do");
  const step = pop();
  frame.index += step;
  push(step > 0 ? (frame.index >= frame.limit ? -1 : 0)
                : (frame.index < frame.limit ? -1 : 0));
});
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

// create — the seed of all defining words. The created word pushes its
// data address; does> (below) can later attach behavior to it. With the
// pair, core.fs defines variable AND constant in Forth.
prim("create", () => {
  const name = input.nextToken();
  if (name === null) throw new Error("create needs a name");
  defineWord({ name, immediate: false, dataAddr: here });
});

// (does>) runs INSIDE a defining word, e.g. inside constant:
//     : constant create , does> @ ;
// At `100 constant limit` time: create defines limit, `,` stores 100, then
// (does>) grabs the code address AFTER itself (the @ ;) and attaches it to
// limit as its runtime behavior — then returns early, since that code
// belongs to limit now, not to constant.
const XT_DOES = prim("(does>)", () => {
  latest.doesAddr = ip;  // latest = the word create just made
  ip = rpop();           // return from the defining word immediately
});

prim("does>", () => {
  mustBeCompiling("does>");
  compile(XT_DOES);
}, true);

// recurse — call the word being defined (its name is hidden until ; so
// you must ask for it explicitly; that's standard Forth).
prim("recurse", () => {
  mustBeCompiling("recurse");
  compile(pendingXt);
}, true);

// pick: 0 pick = dup, 1 pick = over, n pick copies the nth-from-top
prim("pick", () => push(peek(pop())));

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

// ------------------------------------------------------------------ strings
//
// A string is ( addr len ) — an address and a count, two cells on the
// stack, pointing at characters stored one per cell in memory. `type`
// prints one. s" compiles the characters inline (like ." does) but pushes
// addr/len at runtime instead of printing.

prim("type", () => {          // ( addr len -- )
  const len = pop(), addr = pop();
  let s = "";
  for (let k = 0; k < len; k++) s += String.fromCharCode(mem[checkAddr(addr + k)]);
  write(s);
});

const PAD = MEM_SIZE - 256;   // transient buffer for interpret-state s"

const XT_SQ = prim('(s")', () => {
  const len = mem[checkAddr(ip++)];
  push(ip);                   // the characters live right here in the code
  push(len);
  ip += len;
});

prim('s"', () => {
  const text = input.parse('"');
  if (state === 1) {
    compile(XT_SQ);
    compile(text.length);
    for (const ch of text) compile(ch.charCodeAt(0));
  } else {
    for (let k = 0; k < text.length; k++) mem[PAD + k] = text.charCodeAt(k);
    push(PAD);
    push(text.length);
  }
}, true);

prim("char", () => {          // char A  ( -- 65 )
  const t = input.nextToken();
  if (t === null) throw new Error("char needs a character");
  push(t.charCodeAt(0));
});

prim("[char]", () => {        // compile-time char
  mustBeCompiling("[char]");
  const t = input.nextToken();
  if (t === null) throw new Error("[char] needs a character");
  compile(XT_LIT);
  compile(t.charCodeAt(0));
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
  write("kelforth stage 5 — the playground. Type `bye` to quit, `words` to look around.\n");
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
