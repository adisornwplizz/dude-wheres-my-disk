# Dude, Where’s My Disk?

<img src="Resources/AppIcon.png" width="96" alt="An orange floppy disk with a question mark">

You closed the ticket. The worktree still lives here rent-free. Find it on your Mac.

A native macOS app for reviewing Git worktrees across projects. See how much disk space each checkout uses, which processes are working there, and what you need to check before removing it.

## Build and open

On macOS 14 or later, install the Xcode Command Line Tools, then run the following from the repository root. The build script compiles the Swift sources and signs the app locally.

```sh
./build.sh
open "build/Dude, Where’s My Disk.app"
```

## Find the worktrees worth checking first

1. Choose **Add Workspace…** and select a project folder. If it contains multiple repositories, choose which ones to include. The app discovers the root repository and repositories in its immediate subfolders.
2. Select the workspace for a combined view, or a child repository for a narrower scan. **Workspace options (…) → Scan Storage** measures that folder and its registered linked worktrees, including checkouts elsewhere on disk.
3. Open **By reason** to see the first cleanup blocker for each worktree. Expand a group to see its largest checkouts first. **Largest first** ranks worktrees across reasons. **All** includes checkouts currently in use and those eligible for removal.
4. Each worktree row shows its local cleanup reason and size. Its **Task description** card shows up to two recent commit subjects unique to the branch, even before you analyze. **Analyze all** adds a timestamped description from Git or your local model. Choose **Clean…** on an eligible row to review the path and generated items. Confirming **Remove Worktree** permanently removes the checkout and keeps its local branch. Added workspaces and their selected repositories are remembered on this Mac.

**On disk** counts allocated space once across overlapping folders and hard links in the selected scope. **Cleanable estimate** counts eligible checkouts and discounts files with surviving hard links outside them. Individual rows show the whole checkout, so the size of a parent can include a child listed elsewhere. APFS snapshots and clones can also reduce the space actually returned to the volume.

**In use by** shows processes macOS lets the app see whose working directory is inside the checkout. An editor with an open file can have its working directory elsewhere. Finish any sessions still writing there before removal.

## Monitor all added workspaces

<img src="Resources/DiskBuddyScan.gif" width="84" alt="An orange floppy disk mascot taking little steps while scanning">

The menu bar uses a monochrome template version of the mascot. It blinks while idle, moves while scanning, and uses a still frame when macOS Reduce Motion is enabled.

The menu bar shows disk usage for **linked worktrees only**. The **On disk** total in Workspace options also includes the main checkout. A single pass across the registered workspaces counts overlapping folders and hard links once. The popover shows per-workspace usage, the last scan time and a partial-scan indicator if a folder could not be measured.

Close the main window to keep monitoring in the menu bar. Use **Settings…** to select a refresh interval (15 minutes by default, or manual only). **Open App** brings back the full window and **Quit** stops the monitor.

The main window opens on **All workspaces**. Each row shows a checkout, its size, its first cleanup reason and a next step. The header’s **Analyze all** checks every added workspace. Your sidebar selection filters the visible results and stays selected while the analysis runs. If a local Ollama model is configured, the app also asks it to explain the results. Progress and recommendations appear in the same window. **Ready to clean** in the list filter shows eligible worktrees. The merge line identifies ancestry, a matching snapshot on the local default branch, or unverified commits. **Clean…** on the right of an eligible task card shows the path and generated items inline before you confirm removal. The local branch stays available.

For **Task description**, Analyze reads recent branch commit subjects, changed paths and bounded diff excerpts relative to the shared ancestor with the local default branch. It also samples staged and unstaged changes and lists untracked names. With a local model, each checkout gets a separate loopback request for a short Thai explanation. Without one, the card shows Git subjects and filenames. The latest description is saved on this Mac, survives a restart and background scans, and is labeled with its analysis time. Repeat **Analyze all** to reuse descriptions for the same model, checkout commit, comparison base, staged changes and working files. The header counts reused and updated descriptions. The first run after upgrading from 0.9.1 establishes this baseline. Git still checks cleanup eligibility on every scan. A large diff is sampled, so the description may cover only part of the work. Cleanup eligibility always comes from Git and local checks.

The separate cleanup explanation uses aggregate counts and up to 48 anonymized worktree entries. Optional cloud worktree reports receive only sanitized cleanup facts. Scheduled background scans use local Git and disk checks. Git operates on the refs and objects already present on this Mac.

## How cleanup decisions work

| Local assessment | What to do |
| --- | --- |
| **Can remove** | Inspect the path and approve the listed generated items if you want to reclaim their space. |
| **Keep** | Read the specific blocker. Common examples include an active process, uncommitted changes, untracked files, ignored local configuration, or a nested checkout. |
| **Review required** | Check the reported uncertainty. Examples include detached HEAD, missing folders, and commits whose integration the app could not verify. |

The app checks the local default branch. Commit ancestry establishes a regular merge. A squash merge can produce a new commit ID, so the app also checks up to 512 first-parent commits on that branch after the fork. An exact match of the entire tracked Git tree establishes that the worktree’s final snapshot appeared in that history. Other commit arrangements can still require manual review.

Before removal, the app rechecks the registration, Git state, generated-item list and visible process activity. It protects a parent checkout when it finds a nested repository marker. Git-ignored directories named `node_modules`, `.build` or `DerivedData`, plus root-relative `dist/`, `.yarn/cache/` and `.yarn/install-state.gz`, may be included after explicit confirmation. Approval covers everything inside each listed directory. A file such as a root-level ignored `.env` blocks removal.

## Optional AI explanations

**Ollama (Local)** is the first choice on a fresh installation. With Ollama running and a chat model installed, open **Settings → Configure…**, press **Connect**, choose an installed model, and press **Save**. The app uses the standard loopback address `http://127.0.0.1:11434`. Model discovery fetches metadata. Inference starts when you choose **Analyze all** or request a local worktree report. The app requires a local model and uses Ollama's local-only model selector. [Ollama API](https://docs.ollama.com/api)

For a single worktree, enable **Allow cloud for individual worktrees** in Settings. This switch defaults to off, including for existing installations. Choose **Configure…**, then select **OpenAI**, **Claude Platform** or **DeepSeek**. Save a provider key in macOS Keychain and use **Connect** to retrieve that provider's model list. Connecting queries the catalog. Sending an analysis is a separate action.

In a workspace or repository, right-click a worktree and choose **View worktree report…** to see its local Git verdict and preview the evidence JSON. It includes the verdict, first blocker category, merge-proof type and relevant counts. Paths, source code, diffs, branch names and commit messages stay on the Mac. An optional model explains the evidence in Thai. Removing a worktree still requires local checks and your confirmation.

## Token usage

The sidebar shows today’s total and all-time usage. Its bar splits today’s tokens into input and output. **Settings → Token usage** shows input and output totals for today and all time on this Mac. **Analysis history** shows each Analyze all run or individual model report, including completed requests from a cancelled run. Usage starts when this version is installed. It uses counts returned by the model provider. A total marked **≈** includes estimates based on UTF-8 text size (roughly four bytes per token). A request interrupted before it returns usage can be missing. Git-only checks consume zero model tokens. The history stores timestamps, counts and the type of run locally.

## Run the tests

```sh
./Tests/verify.sh
./Tests/verify-workspaces.sh
./Tests/verify-storage.sh
./Tests/verify-ai.sh
./Tests/verify-batch.sh
```

The tests exercise Git cleanup using disposable repositories, workspace discovery, process activity, disk accounting and provider request handling. The AI test intercepts requests with dummy credentials.

## Inspiration

The idea of reclaiming disk space from forgotten developer worktrees was inspired by [CleanMyWT](https://github.com/poomsc/Clean-My-Worktree).
