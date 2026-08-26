# OpenAIQuotaFuse

[English](README.md) | 日本語

OpenAIQuotaFuse は、OpenAI API の無料トークン枠を安全側に見積もって使い、無料枠に収まらない場合だけ小さな年間上限つきで有料 fallback する quota guard です。

## まずこれだけ

    git clone https://github.com/oqzl/OpenAIQuotaFuse.git
    cd OpenAIQuotaFuse
    cp .env.example .env
    $EDITOR .env
    ./shell/openai-quota-fuse.sh run "富士山の高さは？"

必要なのは Bash、curl、jq です。

`OPENAI_ADMIN_KEY` は Organization Usage と Organization Costs の取得だけに使います。Organization Owner は API Platform の Organization settings → Admin keys から作成できます: https://platform.openai.com/settings/organization/admin-keys 。通常の project `OPENAI_API_KEY` は input token 数の取得と推論に使い、Admin key とは分離してください。

## モデル選択

まず無料 quota を使います。既定の `low` は:

    gpt-5.6-terra → gpt-5.6-luna → gpt-5.6-sol

Terra と Luna は high-volume の無料 token quota を共有するため、無料枠では quota token あたりの能力を優先して Terra を先にします。難しい仕事で `-q high` を明示した場合は:

    gpt-5.6-sol → gpt-5.6-terra → gpt-5.6-luna

無料候補が保守的な予約量を確保できない場合だけ、年間有料予算を使えます。既定は `$5` です。

    OPENAI_ANNUAL_PAID_BUDGET_USD=5
    OPENAI_ANNUAL_PAID_BUDGET_USD=0   # 有料 fallback を無効化

通常の有料 fallback はドル単価を重視して無料枠とは別順序です。

    gpt-5.6-luna → gpt-5.6-terra → gpt-5.6-sol

年間上限の実支出の正本には Organization Costs API を使います。そのため、OpenAIQuotaFuse を通さず `curl` や別アプリから直接使った API 支出も、OpenAI 側で Costs に計上された後は次回の判定に含まれます。

ただし Costs への反映には遅延があり得るため、直近の QuotaFuse 有料実行についてはローカル ledger も保守的な lag guard として加算します。一時的に二重計上になる場合がありますが、`$5` を使い切ることより意図しない有料超過を避けることを優先します。

現在値は次で確認できます。

    ./shell/openai-quota-fuse.sh costs
    ./shell/openai-quota-fuse.sh costs -r

通常表示では `official_costs_usd`、直近の local guard、budget 判定に使う effective spend を分けて表示します。Costs API は 1月1日 00:00 UTC からページングして UTC 暦年全体を集計します。

プリペイド残高や個々の失効日時について、現時点で runtime 判定に使える信頼できる公式 API は確認できていないため、Billing UI のスクレイピングや推測はしません。購入済み credit は現在の OpenAI 公式説明では購入から1年で失効しますが、失効日は runtime model selection には使いません。

## `run`

推論前に `POST /v1/responses/input_tokens` で input token 数を取得し、次を予約します。

    input_tokens + max_output_tokens

入力方法:

    ./shell/openai-quota-fuse.sh run "説明して"
    ./shell/openai-quota-fuse.sh run -i "説明して"
    printf '%s\n' "説明して" | ./shell/openai-quota-fuse.sh run
    ./shell/openai-quota-fuse.sh run -i - < prompt.txt
    ./shell/openai-quota-fuse.sh run -m gpt-5.6-luna -o 256 "一言で説明して"
    ./shell/openai-quota-fuse.sh run -e high "よく考えて答えて"
    ./shell/openai-quota-fuse.sh run -r "Responses API の JSON をそのまま返して"

`-e/--effort` は Responses API の `reasoning.effort` を指定します。`-q/--quality` とは独立です。`quality` はモデル選択順、`effort` は選ばれたモデル内部の推論量を制御します。指定可能値は `none`、`low`、`medium`、`high`、`xhigh`、`max`。省略時はモデル/API の既定値をそのまま使います。

`-r/--raw` では stdout に抽出済み text ではなく Responses API の完全な JSON を出します。quota/model/usage の診断情報は stderr のままです。

Shell 版 P0 は plain text input と model/quality/effort/max-output/raw に意図的に限定します。tools、structured output schema、files/images、`previous_response_id`、任意の Responses API field を中途半端な generic proxy として通しません。それらは quota/accounting 上の意味を定義してから追加します。

旧 positional 形式 `check MODEL TOKENS` と `select TOKENS [MODEL ...]` は 0.x の間は互換維持します。正規形は long/short option とし、positional 互換は 1.0 で削除予定です。

## 中身を確認したくなったら

    ./shell/openai-quota-fuse.sh status
    ./shell/openai-quota-fuse.sh costs
    ./shell/openai-quota-fuse.sh models
    ./shell/openai-quota-fuse.sh select -t 8000
    ./shell/openai-quota-fuse.sh check -m gpt-5.6-sol -t 8000
    ./shell/openai-quota-fuse.sh status -r

## ポリシーと保守

無料枠の会計対象は `models.json`、無料・有料の自動選択方針は `model-selection.json` に置きます。これらが古くなった場合は現在の OpenAI 一次資料を優先します。

incentive 固有の Usage API 挙動を検証し終えるまでは、登録モデルの Usage をすべて消費として数えます。金額会計は、OpenAI が billing と照合する用途で推奨している Organization Costs を使います。モデルポリシーは `bash scripts/audit-model-policy.sh` と週次 workflow で監査します。

言語共通のポリシーは `spec/QUOTA_POLICY.md`、残作業は [docs-ja/TODO.md](docs-ja/TODO.md) を参照してください。
