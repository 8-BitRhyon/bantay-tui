---
name: asd-ste100
description: >
  Enforce ASD-STE100 (Simplified Technical English) specification rules for all
  technical documentation, Markdown files (README, architecture guides, changelogs,
  development plans, specs, ADRs, PR descriptions), and code comments.
  Enforces zero em dashes and zero en dashes (replaced with colons, parentheses,
  hyphens, or separate sentences), strict sentence length limits (<= 20 words for
  procedural instructions, <= 25 words for descriptive text), one topic or instruction
  per sentence, active voice, imperative mood for steps, restricted vocabulary
  (one word = one meaning), no noun stacking (> 3 nouns), and no marketing buzzwords
  or conversational filler. Activate whenever writing, editing, auditing, or reviewing
  technical documentation, Markdown files, or when the user mentions STE, STE100,
  ASD-STE100, or simplified technical English.
---

# ASD-STE100 Simplified Technical English Skill

This skill enforces the principles of **ASD-STE100 (Simplified Technical English)** across all technical documentation, Markdown files, design specifications, architecture manuals, and code comments.

ASD-STE100 is an international specification designed to make technical texts clear, unambiguous, concise, and easy to translate.

---

## 1. Punctuation Rules (Zero Tolerance)

### 1.1 Zero Em Dashes and Zero En Dashes
- Never use em dashes under any circumstance.
- Never use en dashes under any circumstance.
- **Replacements**:
  - **For introductions and definitions**: Use a colon (`:`).
    - *Non-STE*: `The daemon manages agents — autonomous background tasks.`
    - *STE*: `The daemon manages agents: autonomous background tasks.`
  - **For clarifications or parenthetical details**: Use parentheses `(...)`.
    - *Non-STE*: `The window tiling engine — built with spring physics — runs smoothly.`
    - *STE*: `The window tiling engine (built with spring physics) runs smoothly.`
  - **For secondary thoughts or pauses**: Split into two separate sentences.
    - *Non-STE*: `Run the setup script — it installs the background service.`
    - *STE*: `Run the setup script. The script installs the background service.`
  - **For number and version ranges**: Use "to" or "through".
    - *Non-STE*: `Layers 1–153; 35%–100%`
    - *STE*: `Layers 1 through 153; 35% to 100%`
  - **For compound modifiers**: Use a standard ASCII hyphen (`-`).

### 1.2 Other Punctuation Constraints
- **Exclamation Marks (`!`)**: Never use exclamation marks in technical documentation.
- **Semicolons (`;`)**: Avoid semicolons. Split into separate declarative sentences.
- **Slashes (`/`)**: Avoid slashes in running prose. Write "or" or "and" (e.g. "read or write", not "read/write"). Slashes are acceptable only in file paths and CLI flags.

---

## 2. Sentence Length Constraints (ASD-STE100 Rules 1.1 and 1.2)

- **Procedural / Instructional Sentences**: **Maximum 20 words**.
  - Applies to: steps, instructions, commands, action table cells, and procedures.
- **Descriptive Sentences**: **Maximum 25 words**.
  - Applies to: architecture overviews, concept definitions, summaries, and notes.
- **Paragraph Length**: **Maximum 6 sentences** per paragraph.

If a sentence exceeds these limits, split it immediately.

---

## 3. Sentence Structure and Logic (ASD-STE100 Rule 2.1)

- **One Instruction per Sentence**:
  - Do not combine multiple sequential actions with "and" or "then".
  - *Non-STE*: `Open the Settings window and click the General tab.`
  - *STE*: `Open the Settings window. Click the General tab.`
- **One Topic per Sentence**:
  - Express only one technical thought or fact per sentence.
  - Avoid chaining subordinate clauses with "while", "whereby", or similar conjunctions.

---

## 4. Grammar and Voice Rules (ASD-STE100 Section 3)

### 4.1 Active Voice
Always make the agent or subject clear.
- *Non-STE (Passive)*: `The signal is received by the socket listener.`
- *STE (Active)*: `The socket listener receives the signal.`

### 4.2 Imperative Mood for Procedures
Start procedural steps with a direct, base-form imperative verb:
- *STE*: "Run the build script."
- *STE*: "Press `⌥Space` to open the panel."
- *STE*: "Select the target option."

### 4.3 Simple Verb Tenses Only
Use simple present, simple past, and simple future:
- **Use simple present** for system operations: "The daemon monitors active agents."
- **Avoid progressive/continuous forms (`-ing`)**:
  - *Non-STE*: `The daemon is monitoring the processes.`
  - *STE*: `The daemon monitors the processes.`
- **Avoid perfect tenses**:
  - *Non-STE*: `The team has updated the registry.`
  - *STE*: `The team updated the registry.` (or "The registry is up to date.")

### 4.4 Restrict Noun Clusters (ASD-STE100 Rule 2.2)
Do not stack more than three nouns consecutively. Insert prepositions to clarify relationships:
- *Non-STE*: `agent terminal output peek drawer window`
- *STE*: `peek window for agent terminal output`

---

## 5. Vocabulary and Word Choice (One Word = One Meaning)

Use approved technical terms consistently. Do not use synonyms for variety.

### 5.1 Approved Verb Replacements
| Do Not Use | Approved STE Word | Example |
|---|---|---|
| `utilize`, `leverage`, `employ` | **use** | Use the CLI tool. |
| `display`, `exhibit`, `indicate` | **show** | The HUD shows agent status. |
| `initiate`, `commence` | **start** | Start the background service. |
| `terminate`, `abort`, `halt` | **stop** | Stop the active agent. |
| `modify`, `alter` | **change** | Change the column width. |
| `transmit`, `dispatch` | **send** | Send keystrokes to the shell. |
| `retrieve`, `acquire`, `obtain` | **get** | Get the process status. |
| `sanitize`, `purge` | **clean** | Clean the transcript text. |
| `in order to` | **to** | Run the command to build the binary. |
| `due to the fact that` | **because** | The build failed because the file was missing. |
| `as well as` | **and** | Supports Ghostty and Antigravity IDE. |

### 5.2 Banned Filler and Marketing Buzzwords
Never use subjective marketing terms in technical documentation:
- *Banned*: `seamless`, `seamlessly`, `blazing fast`, `out of the box`, `state of the art`, `game changer`, `robust`, `effortless`, `overall`.
- *Replace with*: Concrete metrics, functional facts, or eliminate entirely.

---

## 6. Markdown Formatting Rules

1. **Heading Hierarchy**: Maintain strict sequential heading levels (`#` -> `##` -> `###`). Do not skip levels.
2. **Lists**: Ensure parallel grammatical structure in all list items (all imperative verbs or all noun phrases).
3. **Tables**:
   - Keep table cells concise.
   - Cells must not contain sentences exceeding 25 words.
4. **Code Fences**: Always specify the language identifier (e.g. ````bash`, ````swift`, ````markdown`).

---

## 7. Automated Validation Script

Use the bundled verification tool to validate files against ASD-STE100 rules:

```bash
python3 ~/.gemini/config/skills/asd-ste100/scripts/lint_ste100.py <path-to-file.md>
```

The script verifies:
1. Absence of em dashes and en dashes in prose.
2. Absence of semicolons in prose.
3. Sentence lengths ($\le 20$ words for procedures/lists, $\le 25$ words for descriptions).
4. Table cell lengths ($\le 25$ words).
5. Non-STE phrases (`utilize`, `in order to`, `seamless`, etc.).

---

## 8. Workflow Checklist for Technical Documentation

When writing or editing documentation:
1. **Draft / Edit**: Apply active voice and simple present tense.
2. **Check Punctuation**: Ensure zero em dashes, zero en dashes, and zero semicolons.
3. **Count Words**: Ensure no procedural sentence exceeds 20 words and no descriptive sentence exceeds 25 words.
4. **Run Linter**: Run `python3 ~/.gemini/config/skills/asd-ste100/scripts/lint_ste100.py <file>`.
5. **Verify**: Ensure the linter outputs `✓ PASS` for all inspected files.
