# OpenAIQuotaFuse

[English](README.md) | 日本語

OpenAIQuotaFuse は、OpenAI API の無料トークン枠をできるだけ超えないように API を呼ぶ quota guard です。

## まずこれだけ

    git clone https://github.com/oqzl/OpenAIQuotaFuse.git
    cd OpenAIQuotaFuse
    cp .env.example .env
    $EDITOR .env
    ./shell/openai-quota-fuse.sh run "富士山の高さは？"

必要なのは Bash、curl、jq です。`OPENAI_ADMIN_KEY` は Organization Usage の取得、`OPENAI_API_KEY` は通常の Responses API 呼び出しに使います。

普段は `run` だけ覚えれば構いません。既定の `low` profile は次の順です。

    gpt-5.6-luna → gpt-5.6-terra → gpt-5.6-sol

難しい仕事だけ `-q high` を明示します。

    gpt-5.6-sol → gpt-5.6-luna → gpt-5.6-terra

## `run` が確認するもの

推論前に、候補モデルと実際の prompt を `POST /v1/responses/input_tokens` に渡して公式の input token 数を取得します。予約する quota は次です。

    公式 input_tokens + max_output_tokens

この予約量が無料 quota に収まることを確認してから `POST /v1/responses` を実行します。完了後は実レスポンスの `usage.input_tokens`、`usage.output_tokens`、`usage.total_tokens` を診断情報として stderr に表示します。

    quota: OK (input=12 + max_output=256 => reserve=268 tokens)
    model: gpt-5.6-luna
    usage: input=12 output=34 total=46

モデル固定と最大出力指定:

    ./shell/openai-quota-fuse.sh run -m gpt-5.6-luna -o 256 "一言で説明して"

なお、Organization Usage から無料 quota の残量を導く会計自体は、無料枠を過大評価しない安全側の判定を継続します。実際の incentive 適用量より早く停止する場合があります。

## 中身を確認したくなったら

    ./shell/openai-quota-fuse.sh status
    ./shell/openai-quota-fuse.sh models
    ./shell/openai-quota-fuse.sh select -t 8000
    ./shell/openai-quota-fuse.sh check -m gpt-5.6-sol -t 8000
    ./shell/openai-quota-fuse.sh status -r

## ポリシーと保守

無料枠の会計対象は `models.json`、自動選択候補は `model-selection.json` に分離しています。quota group は容量分類であり、モデル品質やタスク難易度ではありません。

incentive 固有の Usage API 挙動を検証し終えるまでは、登録モデルの Usage をすべて消費として数えます。モデルポリシーは `bash scripts/audit-model-policy.sh` と週次 workflow で監査します。

言語共通のポリシーは `spec/QUOTA_POLICY.md`、残作業は [docs-ja/TODO.md](docs-ja/TODO.md) を参照してください。
