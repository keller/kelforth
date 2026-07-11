// kelforth stage 2 — control flow and the compiler
//
// New since stage 1:
//   - a REAL compiler: colon definitions compile to instruction arrays
//     (early binding — words are resolved at definition time)
//   - interpret state vs compile state, and IMMEDIATE words
//   - comparisons and boolean flags ( -1 = true, 0 = false )
//   - control flow: if/else/then, begin/until, begin/while/repeat, do/loop
//   - ." for printing text
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
    // Read raw text up to a delimiter (used by ." to grab the string).
    // Skips the single space that separates the word from its text.
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
// A colon definition is no longer a list of tokens — it is compiled code:
// an array of simple instruction objects, one of:
//
//   { op: "lit", value }       push a constant
//   { op: "call", word }       execute another word
//   { op: "branch", target }   jump always
//   { op: "0branch", target }  pop; jump if zero
//   { op: "print", text }      compiled by ."
//
// Word references are resolved when the definition is COMPILED (early
// binding), and control flow becomes branch instructions with numeric
// targets, exactly like a real instruction set.
//
// A word is { name, immediate, fn } for a primitive or
// { name, immediate, code } for a compiled colon definition. `immediate`
// words execute even during compilation.

const dict = new Map();

function prim(name, fn, immediate = false) {
  dict.set(name.toLowerCase(), { name, immediate, fn });
}

function find(name) {
  return dict.get(name.toLowerCase());
}

// ------------------------------------------------------------ compiler state
//
// THE big idea of this stage. The interpreter is always in one of two states:
//   interpreting: execute each word as it arrives
//   compiling:    append each word to the definition being built
// ...except IMMEDIATE words, which execute even while compiling. Control-flow
// words are immediate: they run at compile time and emit/patch branches.

let compiling = false;
let pendingName = "";
let pendingCode = [];
const cfStack = []; // control-flow stack: branch origins & loop targets

function mustBeCompiling(name) {
  if (!compiling) throw new Error(`${name} is compile-only (use it inside a definition)`);
}

// ---------------------------------------------------------- inner interpreter
//
// Runs compiled code. `ip` is the instruction pointer; branches assign it.

function run(code) {
  let ip = 0;
  while (ip < code.length) {
    const instr = code[ip++];
    switch (instr.op) {
      case "lit":     push(instr.value); break;
      case "call":    execute(instr.word); break;
      case "branch":  ip = instr.target; break;
      case "0branch": if (pop() === 0) ip = instr.target; break;
      case "print":   write(instr.text); break;
    }
  }
}

function execute(word) {
  if (word.fn) word.fn();
  else run(word.code);
}

// ------------------------------------------------------------ the primitives

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
prim("negate", () => push(-pop()));

// comparisons — a flag is a number: -1 means true, 0 means false.
// (All bits set / no bits set, so bitwise AND/OR double as logical AND/OR.)
prim("=",  () => { const b = pop(), a = pop(); push(a === b ? -1 : 0); });
prim("<>", () => { const b = pop(), a = pop(); push(a !== b ? -1 : 0); });
prim("<",  () => { const b = pop(), a = pop(); push(a < b ? -1 : 0); });
prim(">",  () => { const b = pop(), a = pop(); push(a > b ? -1 : 0); });
prim("<=", () => { const b = pop(), a = pop(); push(a <= b ? -1 : 0); });
prim(">=", () => { const b = pop(), a = pop(); push(a >= b ? -1 : 0); });
prim("0=", () => push(pop() === 0 ? -1 : 0));
prim("0<", () => push(pop() < 0 ? -1 : 0));
prim("0>", () => push(pop() > 0 ? -1 : 0));
prim("and",    () => { const b = pop(), a = pop(); push(a & b); });
prim("or",     () => { const b = pop(), a = pop(); push(a | b); });
prim("xor",    () => { const b = pop(), a = pop(); push(a ^ b); });
prim("invert", () => push(~pop()));
prim("true",   () => push(-1));
prim("false",  () => push(0));

// stack shuffling
prim("dup",   () => push(peek(0)));
prim("drop",  () => { pop(); });
prim("swap",  () => { const b = pop(), a = pop(); push(b); push(a); });
prim("over",  () => push(peek(1)));
prim("rot",   () => { const c = pop(), b = pop(), a = pop(); push(b); push(c); push(a); });
prim("nip",   () => { const b = pop(); pop(); push(b); });
prim("tuck",  () => { const b = pop(), a = pop(); push(b); push(a); push(b); });
prim("depth", () => push(stack.length));

// output
prim(".",    () => write(pop() + " "));
prim(".s",   () => write(`<${stack.length}> ${stack.join(" ")} `));
prim("emit", () => write(String.fromCharCode(pop())));
prim("cr",   () => write("\n"));
prim("space",() => write(" "));
prim("bye",  () => process.exit(0));

// comments (immediate, so they work inside definitions too)
prim("\\", () => input.skipUntil("\n"), true);
prim("(",  () => input.skipUntil(")"), true);

// ---------------------------------------------------------- the colon compiler
//
// `:` just flips the state switch. `;` is IMMEDIATE — it must run during
// compilation (otherwise it would be compiled into the definition, and
// nothing would ever end). This is why definitions can now span lines:
// the state lives between calls to interpret().

prim(":", () => {
  if (compiling) throw new Error("nested : not allowed");
  const name = input.nextToken();
  if (name === null) throw new Error(": needs a name");
  compiling = true;
  pendingName = name;
  pendingCode = [];
});

prim(";", () => {
  mustBeCompiling(";");
  if (cfStack.length > 0) throw new Error(`unbalanced control structure in ${pendingName}`);
  dict.set(pendingName.toLowerCase(), { name: pendingName, immediate: false, code: pendingCode });
  compiling = false;
}, true);

// -------------------------------------------------------- control flow words
//
// All immediate: they run at COMPILE time. `if` compiles a conditional
// branch with a hole for the target and remembers where the hole is;
// `then` fills the hole with the current position. That's the entire trick.

prim("if", () => {
  mustBeCompiling("if");
  cfStack.push(pendingCode.length);              // remember the hole...
  pendingCode.push({ op: "0branch", target: -1 }); // ...compile it
}, true);

prim("then", () => {
  mustBeCompiling("then");
  const hole = cfStack.pop();
  if (hole === undefined) throw new Error("then without if");
  pendingCode[hole].target = pendingCode.length;
}, true);

prim("else", () => {
  mustBeCompiling("else");
  const ifHole = cfStack.pop();
  if (ifHole === undefined) throw new Error("else without if");
  cfStack.push(pendingCode.length);              // new hole: jump over else-part
  pendingCode.push({ op: "branch", target: -1 });
  pendingCode[ifHole].target = pendingCode.length;
}, true);

prim("begin", () => {
  mustBeCompiling("begin");
  cfStack.push(pendingCode.length);              // loop start: a jump target
}, true);

prim("until", () => {
  mustBeCompiling("until");
  const dest = cfStack.pop();
  if (dest === undefined) throw new Error("until without begin");
  pendingCode.push({ op: "0branch", target: dest }); // loop again while false
}, true);

prim("again", () => {
  mustBeCompiling("again");
  const dest = cfStack.pop();
  if (dest === undefined) throw new Error("again without begin");
  pendingCode.push({ op: "branch", target: dest });
}, true);

prim("while", () => {
  mustBeCompiling("while");
  cfStack.push(pendingCode.length);              // hole: exit loop if false
  pendingCode.push({ op: "0branch", target: -1 });
}, true);

prim("repeat", () => {
  mustBeCompiling("repeat");
  const hole = cfStack.pop();
  const dest = cfStack.pop();
  if (hole === undefined || dest === undefined) throw new Error("repeat without begin/while");
  pendingCode.push({ op: "branch", target: dest });
  pendingCode[hole].target = pendingCode.length;
}, true);

// ------------------------------------------------------------ counted loops
//
// `10 0 do ... loop` runs the body with index 0,1,...,9. The loop bookkeeping
// lives on a separate loop stack; `i` reads the current index. do/loop are
// immediate words that compile calls to the runtime primitives (do)/(loop).

const loopStack = [];

prim("(do)", () => {
  const index = pop(), limit = pop();
  loopStack.push({ index, limit });
});

prim("(loop)", () => {
  const frame = loopStack[loopStack.length - 1];
  if (!frame) throw new Error("loop outside do");
  frame.index++;
  push(frame.index >= frame.limit ? -1 : 0); // done? (consumed by 0branch)
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

prim("do", () => {
  mustBeCompiling("do");
  pendingCode.push({ op: "call", word: find("(do)") });
  cfStack.push(pendingCode.length);              // loop body start
}, true);

prim("loop", () => {
  mustBeCompiling("loop");
  const dest = cfStack.pop();
  if (dest === undefined) throw new Error("loop without do");
  pendingCode.push({ op: "call", word: find("(loop)") });
  pendingCode.push({ op: "0branch", target: dest });
  pendingCode.push({ op: "call", word: find("(unloop)") });
}, true);

// ------------------------------------------------------------ printing text
//
// ." is immediate: at compile time it grabs the text up to the closing "
// and compiles a print instruction. In interpret state it just prints.

prim('."', () => {
  const text = input.parse('"');
  if (compiling) pendingCode.push({ op: "print", text });
  else write(text);
}, true);

// ---------------------------------------------------------- the interpreter

function interpret(text) {
  input = makeSource(text);
  for (;;) {
    const token = input.nextToken();
    if (token === null) break;
    const word = find(token);
    if (word) {
      if (compiling && !word.immediate) {
        pendingCode.push({ op: "call", word });  // compile it
      } else {
        execute(word);                            // interpret it
      }
    } else if (/^-?\d+$/.test(token)) {
      const n = parseInt(token, 10);
      if (compiling) pendingCode.push({ op: "lit", value: n });
      else push(n);
    } else {
      compiling = false; // abort a half-built definition
      throw new Error(`undefined word: ${token}`);
    }
  }
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
  write("kelforth stage 2 — control flow. Type `bye` to quit.\n");
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  rl.on("line", (line) => {
    try {
      interpret(line);
      write(compiling ? " compiled\n" : " ok\n"); // mid-definition? say so
    } catch (err) {
      write(`error: ${err.message}\n`);
      stack.length = 0;
      cfStack.length = 0;
      loopStack.length = 0;
    }
    rl.prompt();
  });
  rl.on("close", () => write("\n"));
  rl.prompt();
}
