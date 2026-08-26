# Codex プラグイン

[English](../docs/CODEX_PLUGIN.md)

OpenAIQuotaFuse は Codex プラグインとしてインストールできます。プラグインは `quota-fuse` Skill を含み、実行面には Python 3 CLI を使います。

## なぜプラグイン側は Python か

Codex Skill から shell command は呼べるため、技術的には Bash を捨てる必要はありません。ただしプラグインの境界としては Python の方が適しています。`curl` / `jq` の追加依存を外せて、主要な Codex host platform で扱いやすく、将来の plugin integration からも安定した実装面として利用できるためです。quota policy を `SKILL.md` 側へ複製する必要もありません。

Shell 版は Unix 環境向けの dependency-light reference として残します。Python / Shell はどちらも `models.json`、`model-selection.json`、`spec/QUOTA_POLICY.md` を共有します。

## 重要な責務境界

このプラグインは、すでに実行中の Codex turn のモデルを切り替えるものではありません。Skill は instruction と local resource の束であり、Codex 自身の inference model を turn の途中で差し替える hook ではありません。

したがって Fuse が管理するのは、Codex が明示的に Fuse CLI 経由で dispatch する追加の OpenAI API call です。repository workflow 内の追加推論、評価、分類、生成などを、quota と paid fallback policy の管理下に置く用途を想定します。

## ローカルインストール

現在の Codex plugin discovery は marketplace ベースです。ユーザー単位の開発用インストール例:

1. このリポジトリを固定場所へ clone する。
2. `~/plugins/openai-quota-fuse` へ symlink する。
3. `~/.agents/plugins/marketplace.json` に `openai-quota-fuse` entry を追加する。
4. 認識されなければ Codex を再起動する。

    git clone https://github.com/oqzl/OpenAIQuotaFuse.git ~/src/OpenAIQuotaFuse
    mkdir -p ~/plugins ~/.agents/plugins
    ln -sfn ~/src/OpenAIQuotaFuse ~/plugins/openai-quota-fuse

既存の `plugins` 配列を消さず、次の entry を追加します。

    {
      "name": "openai-quota-fuse",
      "source": {
        "source": "local",
        "path": "./plugins/openai-quota-fuse"
      },
      "policy": {
        "installation": "AVAILABLE",
        "authentication": "ON_INSTALL"
      },
      "category": "Developer Tools"
    }

`~/.agents/plugins/marketplace.json` 内の `./plugins/openai-quota-fuse` は home directory 基準で `~/plugins/openai-quota-fuse` を指します。

## credential

既存 CLI と同じ設定を使います。

- `OPENAI_API_KEY`: 通常の Responses API inference と input-token counting。
- `OPENAI_ADMIN_KEY`: Organization Usage / Costs。
- 必要に応じて `.env` と既存の quota / budget 設定。

Admin API key と通常の inference key は分離したままにします。

## Codex から使う

インストール後は自然言語から bundled `quota-fuse` Skill を利用できます。明示例:

    Quota Fuse で OpenAI API quota を確認して。
    この追加 OpenAI API call は Quota Fuse 経由で実行して。
    8000 token reservation に対して cost-aware な model を Quota Fuse で選んで。

Skill 自体で quota 計算を再実装せず、次の Python CLI に委譲します。

    python3 <plugin-root>/python/openai_quota_fuse.py
