# OpenAIQuotaFuse

[English](README.md) | 日本語

OpenAIQuotaFuse は、OpenAI の Data Sharing Incentive 対象トラフィックに付与される日次無料トークン枠の範囲内へ、原則として API 利用を収めるための OpenAI 専用 quota guard です。

Shell / Python 3 / Swift 6 で同じポリシーを実装し、まず Shell CLI をリファレンス実装とします。

OpenAI の無料対象モデルと quota group の上限は時間とともに変わるため、各実装へハードコードせず、共通の機械可読レジストリ `models.json` に集約します。

## Shell MVP

必要なもの:

- Bash
- curl
- jq
- Organization Usage API を参照できる OpenAI Admin API key

初期設定:

    cp .env.example .env
    $EDITOR .env

現在の quota 残量を保守的に確認:

    ./shell/openai-quota-fuse.sh status

Usage API の生レスポンスを確認:

    ./shell/openai-quota-fuse.sh status --raw

同梱されている無料対象モデルレジストリを確認:

    ./shell/openai-quota-fuse.sh models

指定した推定トークン数のリクエストが収まるか判定:

    ./shell/openai-quota-fuse.sh check gpt-5.6-sol 8000

ユーザー指定の優先順で、無料枠に収まる最初のモデルを選択:

    ./shell/openai-quota-fuse.sh select 8000 \
      gpt-5.6-sol \
      gpt-5.6-luna \
      gpt-5.6-terra

## サンプル

そのまま試せる Shell サンプルを `examples/shell/` に置いています。

    bash examples/shell/status.sh
    bash examples/shell/check-request.sh
    bash examples/shell/select-model.sh

`select-model.sh` は `gpt-5.6-sol` → `gpt-5.6-luna` → `gpt-5.6-terra` の順をユーザーの品質優先順位として指定し、推定 8,000 tokens のリクエストを無料枠内で通せる最初の候補を選択します。

現在の Shell MVP は、`models.json` に登録されたモデルに対する当日の Usage をすべて quota 消費として数えます。実際の incentive 適用量より残量を少なく見積もる可能性はありますが、無料残量を過大評価しないことを優先します。

`models.json` には一次資料 URL と `last_reviewed` を記録します。通常の quota 判定時に Help Center をスクレイピングすることはしません。

言語共通のポリシーは `spec/QUOTA_POLICY.md` を参照してください。
