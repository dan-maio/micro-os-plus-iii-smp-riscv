# µOS++ III SMP on RISC-V (`micro-os-plus-iii-smp-riscv`)

The repositories of the workspace `micro-os-plu-iii-smp-riscv-pr-github` in one repository. Each was a
separate git repository; here each is merged, with its full history, in the folder
it had in the workspace (`git subtree add`, commits not rewritten).

| Folder | Branch | Commit | Its own remote before |
| --- | --- | --- | --- |
| `micro-os-plus-iii/` | `riscv` | `3203081e` | `~/Downloads/GIT/micro-os-plus-iii-riscv-core.git` |
| `micro-os-plus-iii-riscv/` | `smp` | `4825c30` | `~/Downloads/GIT/micro-os-plus-iii-riscv-smp.git` |

One `git clone` gets everything; `git log -- <folder>` shows the history of one part.

The two measurement notes of the MangoPi MQ-Pro Wi-Fi tests
(`micro-os-plus-iii-riscv/mangopi-mq-pro.md` and
`micro-os-plus-iii-riscv/test/mangopi-mq-pro/README.md`) name the test
network as `<SSID>`: the real network name was replaced throughout this
repository's history before it was published. No Wi-Fi credential is
committed; the tests take them at configure time
(`-D WIFI_TEST_SSID=... -D WIFI_TEST_PASS=...`).
