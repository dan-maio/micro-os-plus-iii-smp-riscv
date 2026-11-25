# µOS++ III SMP on RISC-V (`micro-os-plus-iii-smp-riscv`)

The repositories of the workspace `micro-os-plu-iii-smp-riscv-pr-github` in one repository. Each was a
separate git repository; here each is in the folder it had in the workspace: the
kernel merged with its full history (`git subtree add`), the RISC-V port as a git
submodule of its own GitHub repository.

| Folder | How | Branch | Commit | Its own remote before |
| --- | --- | --- | --- | --- |
| `micro-os-plus-iii/` | subtree | `riscv` | `ea5843ba` | `~/Downloads/GIT/micro-os-plus-iii-riscv-core.git` |
| `micro-os-plus-iii-riscv/` | submodule of `dan-maio/micro-os-plus-iii-riscv` | `smp` | `52c84a7` | `~/Downloads/GIT/micro-os-plus-iii-riscv-smp.git` |

Clone with the submodule, or the port folder stays empty:

```bash
git clone --recurse-submodules https://github.com/dan-maio/micro-os-plus-iii-smp-riscv.git
# in a clone made without it:
git submodule update --init
```

`git log -- micro-os-plus-iii` shows the kernel's history;
`git -C micro-os-plus-iii-riscv log` shows the port's.

The port was imported as a subtree too (its history ending at `f3a966a`). On
2026-11-25 that history was merged into `smp` of `dan-maio/micro-os-plus-iii-riscv`,
which until then held only the xPack template commits (`e84b2b7`); the merge,
`52c84a7`, has the same files as `f3a966a`. The subtree folder was then
replaced by the submodule.

To change the port, commit in the submodule and push it to GitHub first, then
record the new commit here:

```bash
git -C micro-os-plus-iii-riscv switch smp     # a fresh clone leaves it on a detached HEAD
# ... edit, build, test ...
git -C micro-os-plus-iii-riscv commit -am "..."
git -C micro-os-plus-iii-riscv push origin smp
git add micro-os-plus-iii-riscv && git commit -m "update micro-os-plus-iii-riscv"
git push --recurse-submodules=check origin main
```

The two measurement notes of the MangoPi MQ-Pro Wi-Fi tests
(`micro-os-plus-iii-riscv/mangopi-mq-pro.md` and
`micro-os-plus-iii-riscv/test/mangopi-mq-pro/README.md`) name the test
network as `<SSID>`: the real network name was replaced throughout this
repository's history before it was published, so the commits differ from
those of the workspace repositories (the kernel's `riscv` was `3203081e`
there, the port's `smp` `4825c30`). The port's history on GitHub is the
replaced one. No Wi-Fi credential is committed; the tests take them at
configure time (`-D WIFI_TEST_SSID=... -D WIFI_TEST_PASS=...`).
