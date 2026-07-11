// check.js — kelforth's whole test suite.
//
// For every stage directory, run each examples/*.fs file with that stage's
// interpreter and diff stdout against the sibling .out file.
//
//   node check.js            run everything
//   node check.js stage2     run one stage (prefix match)

import { execFileSync } from "node:child_process";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL(".", import.meta.url));
const filter = process.argv[2] ?? "";

let pass = 0;
let fail = 0;

const stages = readdirSync(root)
  .filter((d) => /^stage\d/.test(d) && d.startsWith(filter))
  .sort();

for (const stage of stages) {
  const interp = join(root, stage, "kelforth.js");
  const exDir = join(root, stage, "examples");
  if (!existsSync(interp) || !existsSync(exDir)) continue;

  for (const file of readdirSync(exDir).filter((f) => f.endsWith(".fs")).sort()) {
    const fsPath = join(exDir, file);
    const outPath = fsPath.replace(/\.fs$/, ".out");
    if (!existsSync(outPath)) {
      console.log(`??   ${stage}/examples/${file} — no .out file`);
      continue;
    }
    const expected = readFileSync(outPath, "utf8");
    let actual;
    try {
      actual = execFileSync("node", [interp, fsPath], { encoding: "utf8" });
    } catch (err) {
      actual = `INTERPRETER ERROR:\n${err.message}`;
    }
    if (actual === expected) {
      pass++;
      console.log(`ok   ${stage}/examples/${file}`);
    } else {
      fail++;
      console.log(`FAIL ${stage}/examples/${file}`);
      console.log(`  --- expected ---\n${indent(expected)}  --- actual ---\n${indent(actual)}`);
    }
  }
}

function indent(s) {
  return s.split("\n").map((l) => `  | ${l}`).join("\n") + "\n";
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail > 0 ? 1 : 0);
