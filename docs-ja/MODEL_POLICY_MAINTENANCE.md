# モデルポリシーの自動保守

OpenAIQuotaFuse は `models.json` と `model-selection.json` を30日間隔で見直します。週次の `Model policy audit` workflow は、期限超過後に失敗するだけではなく、stale なポリシーを自動更新する構成にします。

## 動作

scheduled workflow は毎週月曜に実行します。`scripts/refresh-model-policy.py` は最初に `model-selection.json:last_reviewed` と `review_interval_days` を比較します。

- review interval 内なら OpenAI API を呼ばず終了する。
- stale なら `GET /v1/models` を取得し、その後 OpenAI の web search を `openai.com` に限定した Responses API のレビューを1回実行する。
- レビューでは data-sharing incentive の quota group、model availability/deprecation、API pricing、無料候補順、有料 fallback 順を確認する。
- 生成された2つのJSONは schema と相互整合性を検証してから書き込む。
- refresh 後に `scripts/audit-model-policy.sh` を独立した guard として実行する。
- validated policy に差分があれば、bot 専用の `automation/model-policy-refresh` branch を更新し、Pull Request を作成または更新する。
- Pull Request は自動 merge しない。

生成PRの本文には変更概要と、レビューが参照した OpenAI 一次資料のURLを載せます。OpenAI 以外の source URL は refresh script 側で拒否します。

## 認証情報

workflow は次の GitHub Actions repository secret を利用できます。

1. `OPENAI_MODEL_POLICY_KEY` — モデルポリシー保守専用の project API key。推奨。
2. `OPENAI_API_KEY` — 専用keyを設定していない場合の fallback。

script はどちらのkeyも出力しません。専用keyにすると revoke / rotate 時の影響範囲をモデルポリシー保守に限定できます。

このリポジトリへの GitHub 接続/API から Actions Secret 自体を登録することはできません。次回の stale review までに repository settings からsecretを追加してください。

refresh model の既定値は `gpt-6.1-sol` です。将来変更する場合は workflow の `MODEL_POLICY_REFRESH_MODEL` で上書きできます。

## GitHub権限

workflow は次を要求します。

- `contents: write`
- `pull-requests: write`

加えて repository / organization 側で GitHub Actions に Pull Request 作成を許可している必要があります。無効の場合、policy生成とvalidationまでは成功しても最後の `gh pr create` が権限エラーになります。

## 手動実行

`workflow_dispatch` に `force_refresh` を用意します。有効にすると30日を経過していなくてもレビューします。新モデル、価格変更、deprecation告知などを即時確認したい場合に使います。

ローカルで、ファイルを書き換えず生成結果だけ検証する場合:

```sh
OPENAI_MODEL_POLICY_KEY=... python3 scripts/refresh-model-policy.py --force --dry-run
```

通常実行は stale な場合だけ API を呼びます。

```sh
OPENAI_MODEL_POLICY_KEY=... python3 scripts/refresh-model-policy.py
```

## 安全境界

自動保守は review-gated にします。

- stale な checked-in assumption より現行 OpenAI 一次資料を優先する。
- broad accounting registry では利用可能な古いmodelを残す。
- 新モデルが出ただけでは削除せず、公式 shutdown date 到達後に除外する。
- 無料 routing と paid fallback は別々に評価する。
- 生成された model ID、pricing、quota group はローカルvalidationを通す。
- 自動mergeしない。

生成PRを人間が確認する工程を最終的なポリシー承認とします。
