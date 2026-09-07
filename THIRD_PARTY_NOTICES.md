# Third-Party Notices

## Production foundation

LoopFwd 的当前原生实现以 [mustafahalabi/agents-island](https://github.com/mustafahalabi/agents-island) 为完整基础，而不是零散参考。

- Upstream commit: `275f5e8bb7984dc25fc0b9ed10b48d1eecb3603c`
- Local destination: `Sources/LoopFwd/`、`assets/`
- License: MIT
- Local changes: LoopFwd branding；三 provider 产品表面；启动权限收敛；移除 Sparkle、installer/release 流程；简化 SwiftPM 和 app bundling；统一卡片圆角。

## JSONC configuration editing

The bundled `jsonc-parser@3.3.1` runtime is unmodified MIT-licensed code from
[Microsoft's node-jsonc-parser](https://github.com/microsoft/node-jsonc-parser).
The six UMD JavaScript files and full MIT license are distributed under
`Integrations/LocalHooks/vendor/jsonc-parser/` and in the App's JSON Hook helper.
Exact file SHA-256 values are in `Integrations/LocalHooks/vendor/checksums.sha256`.
The npm package integrity is
`sha512-HUgH65KyejrUFPvHFPbqOY0rsFip3Bo5wb4ngvdi1EpCYWUQDC5V+Y7mZws+DLkr4M//zQJoanu1SP+87Dv1oQ==`.
No provider settings-loader code is imported or executed for configuration edits.

## Studied, not imported

- [mistralai/mistral-vibe](https://github.com/mistralai/mistral-vibe/tree/6c79ef0e1ee484d7069bc38590d5917d3914cd48) @ `6c79ef0e1ee484d7069bc38590d5917d3914cd48`，官方安装包 `mistral-vibe==2.25.0`：Apache-2.0；核对 Hook 类型、executor、session logger 与审批前后时序。LoopFwd 独立实现事件白名单和只读投影，未导入 Python 源码。
- [xai-org/grok-build](https://github.com/xai-org/grok-build/tree/72a61251fcffb464bcc687aeb5a998e5a98ec0c9) @ `72a61251fcffb464bcc687aeb5a998e5a98ec0c9`：核对官方 session-events schema 1.0 的 types、tracker、持有文件句柄的 EventWriter；LoopFwd 独立实现只读投影，未复制 Rust 源码。当前按事件 schema 校验，不将该源码提交当作已安装二进制的构建身份。
- [qeesung/tmux-scout](https://github.com/qeesung/tmux-scout/tree/25cc2a038d10a726b9d28f2a908c4602e11366b8) @ `25cc2a038d10a726b9d28f2a908c4602e11366b8`：MIT；研究 generic Hook 与 Gemini/Copilot 配置入口，尚未导入代码，不沿用 cwd 身份或结束即成功的推断。
- [vibeislandapp/vibe-island](https://github.com/vibeislandapp/vibe-island)：产品形态；公开仓库没有可 Fork 的应用源码。
- [Octane0411/open-vibe-island](https://github.com/Octane0411/open-vibe-island)：研究 hook envelope、in-app bridge、终端返回和显示器可靠性实践；项目使用 GPL-3.0，LoopFwd 未复制、vendoring 或链接其源码，继续以 MIT 发布。
- [wxtsky/CodeIsland](https://github.com/wxtsky/CodeIsland)：bridge、hook 和 app-server 方向；当前没有源码进入生产目录。
- [y49/tlive](https://github.com/y49/tlive)：Codex app-server、approval race 和失败降级；当前没有源码进入生产目录。
- [xmartlabs/gnomon](https://github.com/xmartlabs/gnomon) @ `c82a07000b273a06c77a5616115abadd7d8fdf08`：核对 Cursor Agent JSONL/sidecar 只读格式；MIT，当前没有源码进入生产目录。
- [xhluca/session-migrate](https://github.com/xhluca/session-migrate) @ `1753c16ad82e7028de10922f753b78ed5a30d9c7`：核对 Cursor workspace key 和会话 metadata schema；MIT，当前没有源码进入生产目录。
- [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) tag `dsh-v0.1.2-alpha.5`, commit `db6bdc3576c2d4e7c965e8e3ed0c2a731eed87f5`：核对官方 Web profile、Session 事件和 profile plugin 安装机制；MIT。LoopFwd 未复制其源码，只打包自己的 observer plugin 并通过该公开接口接入。

## Production agent icons

The 11 provider icons distributed in the App are unmodified dark-theme assets
from `@lobehub/icons-static-png@1.95.0`.

- Upstream project: [lobehub/lobe-icons](https://github.com/lobehub/lobe-icons)
- Package version: `1.95.0`
- License: MIT
- Distributed license: `LICENSES/lobe-icons-MIT.txt`
- Exact production hashes: `assets/agent-icon-checksums.sha256`
- Original npm archive integrity and file mappings: `assets/agent-icon-provenance.json`
- The 0.1.1 source candidate re-imports the App assets from that verified archive;
  previously published 0.1.0 artifacts are not silently replaced.

Claude, Codex, OpenCode, Cursor, Gemini, GitHub Copilot, Qwen, Kimi,
DeepSeek, Grok, Mistral, LoopFwd, and their associated marks belong to their
respective owners. Third-party marks are used only to identify compatible
tools. Their appearance does not imply affiliation, sponsorship, or
endorsement.

## Agents Island MIT license

Copyright (c) 2026 Mustafa Halabi and Mohammad Hammoud

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Lobe Icons MIT license

Copyright (c) 2023 LobeHub

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
