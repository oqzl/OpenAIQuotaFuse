# Codex プラグイン

[English](../docs/CODEX_PLUGIN.md)

OpenAIQuotaFuse は Codex プラグインとしてインストールできます。プラグインは `quota-fuse` Skill を含み、実行面には Python 3 CLI を使います。

## なぜプラグイン側は Python か

Codex Skill から shell command は呼べるため、技術的には Bash を捨てる必要はありません。ただしプラグインの境界としては Python の方が適しています。`curl` / `jq` の追加依存を外せて、主要な Codex host platform で扱いやすく、将来の plugin integration からも安定した実装面として利用できるためです。quota policy を `SKILL.md` 側へ複製する必要もありません。

Shell 版は Unix 環境向けの薄い互換 wrapper として残します。Python / Shell はどちらも `models.json`、`model-selection.json`、`spec/QUOTA_POLICY.md` を共有します。

## 重要な責務境界

このプラグインは、すでに実行中の Codex turn のモデルを切り替えるものではありません。Skill は instruction と local resource の束であり、Codex 自身の inference model を turn の途中で差し替える hook ではありません。

したがって Fuse が管理するのは、Codex が明示的に Fuse CLI 経由で dispatch する追加の OpenAI API call です。repository workflow 内の追加推論、評価、分類、生成などを、quota と paid fallback policy の管理下に置く用途を想定します。

## ローカルインストール

現在の Codex plugin discovery は marketplace ベースです。以下はユーザー単位で使う個人用 marketplace の手順です。

### 1. リポジトリを固定場所へ clone して symlink する

`~/plugins` は最初から存在するとは限らないため、先に作成します。

    git clone https://github.com/oqzl/OpenAIQuotaFuse.git ~/src/OpenAIQuotaFuse
    mkdir -p ~/plugins ~/.agents/plugins
    ln -sfn ~/src/OpenAIQuotaFuse ~/plugins/openai-quota-fuse

`~/.agents/plugins/marketplace.json` 内の `./plugins/openai-quota-fuse` は home directory 基準で `~/plugins/openai-quota-fuse` を指します。

### 2. personal marketplace を作成または更新する

`~/.agents/plugins/marketplace.json` も最初から存在するとは限りません。

まだ存在しない場合は、次の完全な JSON を新規作成します。

    cat > ~/.agents/plugins/marketplace.json <<'JSON'
    {
      "name": "local",
      "interface": {
        "displayName": "Local Plugins"
      },
      "plugins": [
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
      ]
    }
    JSON

既に `~/.agents/plugins/marketplace.json` がある場合はファイル全体を上書きせず、既存の `plugins` 配列へ次の entry だけを追加します。

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

JSON を手編集した場合は、少なくとも構文を確認します。

    python3 -m json.tool ~/.agents/plugins/marketplace.json >/dev/null

### 3. Codex に再読込させる

Codex が起動中なら再起動して personal marketplace を再読込させます。personal marketplace は `~/.agents/plugins/marketplace.json` から暗黙に発見されるため、このファイルについて `codex plugin marketplace add` を別途実行する必要はありません。

認識確認には Codex の Plugin UI、または利用中の Codex CLI が plugin commands を持つ場合は `codex plugin list --available --json` を使います。CLI の plugin command は Codex のバージョンによって変わる可能性があるため、存在しない command を前提にはしません。

この手順は OpenAI の現行 plugin-creator / official plugin の personal marketplace layout に合わせています。

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
