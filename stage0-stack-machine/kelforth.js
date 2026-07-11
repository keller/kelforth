// kelforth stage 0 — the stack machine
//
// The smallest thing that is recognizably Forth: a data stack, a handful of
// built-in "words", and a loop that reads tokens and executes them.
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

// ---------------------------------------------------------------- output

const write = (s) => process.stdout.write(s);

// ---------------------------------------------------------------- the words
//
// A word is just a named action. Every word takes its inputs from the stack
// and leaves its outputs on the stack. The comment after each name is a
// "stack effect": ( inputs -- outputs ), top of stack on the right.

const words = {
  "+": () => { const b = pop(), a = pop(); push(a + b); },        // ( a b -- a+b )
  "-": () => { const b = pop(), a = pop(); push(a - b); },        // ( a b -- a-b )
  "*": () => { const b = pop(), a = pop(); push(a * b); },        // ( a b -- a*b )
  "/": () => {                                                    // ( a b -- a/b )
    const b = pop(), a = pop();
    if (b === 0) throw new Error("division by zero");
    push(Math.trunc(a / b));
  },
  "mod": () => {                                                  // ( a b -- a%b )
    const b = pop(), a = pop();
    if (b === 0) throw new Error("division by zero");
    push(a % b);
  },
  "negate": () => push(-pop()),                                   // ( a -- -a )
  ".": () => write(pop() + " "),                                  // ( a -- ) print top
  ".s": () => write(`<${stack.length}> ${stack.join(" ")} `),     // ( -- ) show stack
  "cr": () => write("\n"),                                        // ( -- ) newline
  "bye": () => process.exit(0),                                   // ( -- ) quit
};

// ---------------------------------------------------------- the interpreter
//
// This is the entire "parser": strip \ comments, split on whitespace.
// Each token is either a word we know or a number literal. That's it —
// Forth has no grammar, no precedence, no expressions.

function interpret(line) {
  const stripped = line.replace(/\\.*$/, ""); // one comfort: \ line comments
  for (const token of stripped.trim().split(/\s+/).filter(Boolean)) {
    const word = words[token.toLowerCase()];
    if (word) {
      word();
    } else if (/^-?\d+$/.test(token)) {
      push(parseInt(token, 10));
    } else {
      throw new Error(`undefined word: ${token}`);
    }
  }
}

// ---------------------------------------------------------------- run modes

const file = process.argv[2];

if (file) {
  for (const line of readFileSync(file, "utf8").split("\n")) {
    try {
      interpret(line);
    } catch (err) {
      console.error(`error: ${err.message}`);
      process.exit(1);
    }
  }
} else {
  write("kelforth stage 0 — the stack machine. Type `bye` to quit.\n");
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  rl.on("line", (line) => {
    try {
      interpret(line);
      write(" ok\n");
    } catch (err) {
      write(`error: ${err.message}\n`);
      stack.length = 0; // a real Forth aborts the line and clears the stack
    }
    rl.prompt();
  });
  rl.on("close", () => write("\n"));
  rl.prompt();
}
