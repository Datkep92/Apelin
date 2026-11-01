# 08 Runtime flows

## A. Project flow
1. create/import project via worker/object.
2. `apelin-project.json` describes product/filter/packaging/layout/build.
3. tooling state published.

## B. Build flow
1. build starts task, task events broadcast artifact info.
2. build worker produces artifact in Apelin data build folder, digest/package md.
3. build attaches handle step/progress.
4. environment task (build install) can coordinate.

## C. Installation
1. install package artifact validates packaging digest vs build.
2. copy into `staging` and hash control file.
3. ManagedPackagePolicy evaluates.
4. detect conflicts via installed `.list` file overlap + unversioned conflict declarations.
5. submits staged copy by fd to irisind.
6. writes installation record after accepted.
7. removal whitelisted + only Apelin-installed.

## D. Toolchains/sdk
1. apelin-environment `toolchainStatus/setup/remove/selfTest`.
2. SDK import + path checks.
3. environment attach/cancel task.
4. install artifact names `toolchain-<id>`, only designated package family.

## E. Agent mode
1. send prompt attach events.
2. confirm approval for build/install/delete based digests.
3. screen consent approval per tree/action.
4. mode per session maintained.
5. DeepSeek/OpenAI compat reasoning normalization.

## F. Git
1. status/diff/stage/commit/init.
2. fetch/pull (fast-forward only).
3. push remote branch.
4. clone/import/workspace.
5. create repo/issue with GitHub consent.
6. distribution publish from release artifacts.

## G. Data/home repair + import
1. mobile `~/Documents/wiki.qaq.apelin`.
2. one-time import from iOS container path.
3. ensure no secondary home confusion on upgrades.
