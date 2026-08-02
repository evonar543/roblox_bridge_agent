import fs from "node:fs";
import path from "node:path";

const [sourcePath, functionName, outputDirectory] = process.argv.slice(2);

if (!sourcePath || !functionName || !outputDirectory) {
  throw new Error(
    "Usage: node tools/extract-luau-function.mjs <source.lua> <functionName> <outputDirectory>",
  );
}

const source = fs.readFileSync(sourcePath, "utf8");
const assignmentPattern = new RegExp(`(?:^|[,;])${escapeRegExp(functionName)}\\s*=\\s*function\\b`, "g");
const matches = [...source.matchAll(assignmentPattern)];

if (matches.length !== 1) {
  throw new Error(`Expected one ${functionName}=function assignment, found ${matches.length}`);
}

const assignmentMatch = matches[0];
const functionStart = source.indexOf("function", assignmentMatch.index);
const tokens = tokenize(source, functionStart);

if (tokens[0]?.value !== "function") {
  throw new Error("Function token was not found at the assignment boundary");
}

let depth = 0;
let functionEnd = -1;
const loopTokens = [];

for (const token of tokens) {
  if (token.type !== "word") {
    continue;
  }

  if (token.value === "function" || token.value === "if" || token.value === "do" || token.value === "repeat") {
    depth += 1;
    if (token.value === "do" || token.value === "repeat") {
      loopTokens.push(token);
    }
    continue;
  }

  if (token.value === "end" || token.value === "until") {
    depth -= 1;
    if (depth === 0) {
      functionEnd = token.end;
      break;
    }
    if (depth < 0) {
      throw new Error(`Block depth became negative at source offset ${token.start}`);
    }
  }
}

if (functionEnd < 0) {
  throw new Error(`Could not find the closing end for ${functionName}`);
}

const functionSource = source.slice(functionStart, functionEnd);
const localLoopTokens = loopTokens.filter((token) => token.start >= functionStart && token.end <= functionEnd);
let instrumentedSource = functionSource;

for (const token of [...localLoopTokens].sort((a, b) => b.end - a.end)) {
  const insertionOffset = token.end - functionStart;
  instrumentedSource =
    instrumentedSource.slice(0, insertionOffset) +
    " __RBA_LUARMOR_BUDGET_TICK();" +
    instrumentedSource.slice(insertionOffset);
}

const suffix = source.slice(functionEnd, functionEnd + 32);
const expectedNextAssignment = new RegExp(`^\\s*,\\s*[A-Za-z_]\\w*\\s*=`).test(suffix);
if (!expectedNextAssignment) {
  throw new Error(`Function boundary does not end before another table member: ${JSON.stringify(suffix)}`);
}

fs.mkdirSync(outputDirectory, { recursive: true });
const rawOutputPath = path.join(outputDirectory, `${functionName}.raw.luau`);
const instrumentedOutputPath = path.join(outputDirectory, `${functionName}.budgeted.luau`);
const metadataOutputPath = path.join(outputDirectory, `${functionName}.metadata.json`);

fs.writeFileSync(rawOutputPath, functionSource);
fs.writeFileSync(instrumentedOutputPath, instrumentedSource);

const metadata = {
  version: 1,
  functionName,
  sourcePath: path.resolve(sourcePath),
  functionStart,
  functionEnd,
  sourceBytes: Buffer.byteLength(functionSource),
  instrumentedBytes: Buffer.byteLength(instrumentedSource),
  loopCheckpointCount: localLoopTokens.length,
  loopCheckpoints: localLoopTokens.map((token, index) => ({
    index: index + 1,
    keyword: token.value,
    sourceOffset: token.start,
    functionOffset: token.start - functionStart,
  })),
  followingSource: suffix,
};

fs.writeFileSync(metadataOutputPath, `${JSON.stringify(metadata, null, 2)}\n`);

process.stdout.write(`${JSON.stringify({
  rawOutputPath,
  instrumentedOutputPath,
  metadataOutputPath,
  functionStart,
  functionEnd,
  sourceBytes: metadata.sourceBytes,
  instrumentedBytes: metadata.instrumentedBytes,
  loopCheckpointCount: metadata.loopCheckpointCount,
})}\n`);

function tokenize(text, startOffset) {
  const output = [];
  let index = startOffset;

  while (index < text.length) {
    const char = text[index];
    const next = text[index + 1];

    if (/\s/.test(char)) {
      index += 1;
      continue;
    }

    if (char === "-" && next === "-") {
      const longComment = readLongBracket(text, index + 2);
      if (longComment) {
        index = longComment.end;
      } else {
        const newline = text.indexOf("\n", index + 2);
        index = newline < 0 ? text.length : newline + 1;
      }
      continue;
    }

    if (char === "\"" || char === "'" || char === "`") {
      index = readQuotedString(text, index, char);
      continue;
    }

    if (char === "[") {
      const longString = readLongBracket(text, index);
      if (longString) {
        index = longString.end;
        continue;
      }
    }

    if (/[A-Za-z_]/.test(char)) {
      const tokenStart = index;
      index += 1;
      while (index < text.length && /[A-Za-z0-9_]/.test(text[index])) {
        index += 1;
      }
      output.push({ type: "word", value: text.slice(tokenStart, index), start: tokenStart, end: index });
      continue;
    }

    output.push({ type: "symbol", value: char, start: index, end: index + 1 });
    index += 1;
  }

  return output;
}

function readQuotedString(text, start, quote) {
  let index = start + 1;
  while (index < text.length) {
    if (text[index] === "\\") {
      index += 2;
      continue;
    }
    if (text[index] === quote) {
      return index + 1;
    }
    index += 1;
  }
  throw new Error(`Unterminated quoted string at source offset ${start}`);
}

function readLongBracket(text, start) {
  if (text[start] !== "[") {
    return null;
  }

  let equalsCount = 0;
  let index = start + 1;
  while (text[index] === "=") {
    equalsCount += 1;
    index += 1;
  }
  if (text[index] !== "[") {
    return null;
  }

  const close = `]${"=".repeat(equalsCount)}]`;
  const closeIndex = text.indexOf(close, index + 1);
  if (closeIndex < 0) {
    throw new Error(`Unterminated long bracket at source offset ${start}`);
  }
  return { end: closeIndex + close.length };
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
