# OpenAIQuotaFuse

[English](README.md) | 日本語

OpenAIQuotaFuse は、OpenAI の Data Sharing Incentive 対象トラフィックに付与される日次無料トークン枠の範囲内へ、原則として API 利用を収めるための OpenAI 専用 quota guard です。

Shell / Python 3 / Swift 6 で同じポリシーを実装し、まず Shell CLI をリファレンス実装とします。

OpenAI の無料対象モデルと quota group の上限は時間とともに変わるため、各実装へハードコードせず、共通の機械可読レジストリ `models.json` に集約します。`models.json` は無料枠の会計対象を広く保持し、自動選択で実際に使う候補は `model-selection.json` に分離します。

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

同梱されている無料対象モデルレジストリと既定の選択順を確認:

    ./shell/openai-quota-fuse.sh models

指定した推定トークン数のリクエストが収まるか判定:

    ./shell/openai-quota-fuse.sh check gpt-5.6-sol 8000

`model-selection.json` の既定順で選択:

    ./shell/openai-quota-fuse.sh select 8000

呼び出しごとに独自の優先順を指定することもできます:

    ./shell/openai-quota-fuse.sh select 8000 \
      gpt-5.6-sol \
      gpt-5.6-luna \
      gpt-5.6-terra

## サンプル

そのまま試せる Shell サンプルを `examples/shell/` に置いています。

    bash examples/shell/status.sh
    bash examples/shell/check-request.sh
    bash examples/shell/select-model.sh

`select-model.sh` は `model-selection.json` の既定候補を使います。

## モデルポリシーの定期監査

`models.json` は quota 会計のための対象モデル一覧、`model-selection.json` は実際に自動選択する候補一覧です。古いがまだ対象のモデルを会計対象から消すと Usage を取りこぼすため、この2つは分離しています。

`scripts/audit-model-policy.sh` は、選択候補が会計レジストリに含まれていることと、レビュー期限を検証します。

    bash scripts/audit-model-policy.sh

`.github/workflows/model-policy-audit.yml` でも毎週監査します。`model-selection.json` の既定レビュー間隔は30日で、期限を超えると Action が失敗し、無料対象、Deprecated 状態、API単価、同一quota group内で古い候補を残す理由を再確認するよう促します。

現在の Shell MVP は、`models.json` に登録されたモデルに対する当日の Usage をすべて quota 消費として数えます。実際の incentive 適用量より残量を少なく見積もる可能性はありますが、無料残量を過大評価しないことを優先します。

`models.json` には一次資料 URL と `last_reviewed` を記録します。通常の quota 判定時に Help Center をスクレイピングすることはしません。

言語共通のポリシーは `spec/QUOTA_POLICY.md` を参照してください。
