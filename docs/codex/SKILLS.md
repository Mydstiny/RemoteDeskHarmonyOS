# 项目开发 skill

`remotedesk-harmonyos-dev` 由私有仓库
[Mydstiny/remotedesk-harmonyos-dev-skill](https://github.com/Mydstiny/remotedesk-harmonyos-dev-skill)
独立进行 Git 管理。当前开发基准为 API 26。

## 安装

有私有仓库访问权限时，从应用根目录执行：

```sh
git clone https://github.com/Mydstiny/remotedesk-harmonyos-dev-skill.git .agents/skills/remotedesk-harmonyos-dev
```

目标目录必须不存在；已有目录时先核对内容与独立 Git 状态，不能覆盖本地修改。
本应用忽略此目录，且没有 submodule/gitlink；没有安装 skill 也能正常构建 App。
skill 自己的 `.git` 是普通独立 checkout，不是 App 的 Git worktree。

## 使用和维护

Codex 可按项目问题选用，也可显式使用 `$remotedesk-harmonyos-dev`。
源码/历史引用依赖当前应用 checkout；技能目录内的 Git 根是 skill，应用命令必须
回到应用根执行。避免在两个仓库中提交同一份内容。

```sh
git -C .agents/skills/remotedesk-harmonyos-dev status --short --branch
git -C .agents/skills/remotedesk-harmonyos-dev pull --ff-only
```

skill 内容、脚本、测试和使用反馈都在私有仓库通过分支/PR 管理。
用户已明确：skill 本体开发不运行 App 门禁；执行自身结构校验、引用审计、
适用的测试和独立复核。实际修改 App 时仍执行应用规则。

## 迁移边界

2026-09-07 从应用中已提交的 19 文件 skill 包迁出，保留原文件、许可与来源。
迁移只解除应用 Git 的跟踪，不删除本机 skill 内容；后续更新由私有远端负责。
原应用历史中的 skill 提交仍保留，本次不重写应用历史或推送其私有 archive。
