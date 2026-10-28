# UR 测试向量

都是用脚本从上游源文件原样提取的，没有手抄。格式说明见 `docs/ur-types.md` 第 5 节。

| 文件 | 来源 | 许可证 |
|---|---|---|
| `bc-ur.json` | [URKit](https://github.com/BlockchainCommons/URKit) `ebba59b2` 的 `Tests/URKitTests/{FountainCodes,UR,Bytewords}Tests.swift`；[bc-ur](https://github.com/BlockchainCommons/bc-ur) `test/test.cpp`；BCR-2020-005 / BCR-2020-012；bc-ur-rust `src/lib.rs` | BSD-2-Clause-Patent，Copyright © 2020 Blockchain Commons, LLC |
| `bc-ur.json` 里的 `ur_rs_crypto_request` | [ur-rs](https://github.com/dspicher/ur-rs) `src/ur.rs` | MIT |
| `eip4527-keystone.json` | [keystone-airgaped-base](https://github.com/KeystoneHQ/keystone-airgaped-base) `packages/ur-registry-eth/__tests__`；[keystone-sdk-rust](https://github.com/KeystoneHQ/keystone-sdk-rust) `libs/ur-registry` | ISC（package.json 声明）；MIT |
