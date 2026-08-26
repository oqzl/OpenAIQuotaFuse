# OpenAIQuotaFuse

[English](README.md) | 日本語

OpenAIQuotaFuse は、OpenAI API の無料トークン枠を安全側に見積もって使い、無料枠に収まらない場合だけ小さな年間上限つきで有料 fallback する quota guard です。

## まずこれだけ

    git clone https://github.com/oqzl/OpenAIQuotaFuse.git
    cd OpenAIQuotaFuse
    cp .env.example .env
    $EDITOR .env
    python3 python/openai_quota_fuse.py run "富士山の高さは？"

Python 3 CLI を正規実装とし、Codex プラグインからもこれを実行面として使います。Python 標準ライブラリだけで動作します。Unix 環境では `./shell/openai-quota-fuse.sh` も使えますが、これは同じ Python CLI を呼ぶ薄い Bash 互換 wrapper です。別の quota logic は持たないため、必要なのは Bash と Python 3 です。

`OPENAI_ADMIN_KEY` は Organization Usage と Organization Costs の取得だけに使います。Organization Owner は API Platform の Organization settings → Admin keys から作成できます: https://platform.openai.com/settings/organization/admin-keys 。通常の project `OPENAI_API_KEY` は input token 数の取得と推論に使い、Admin key とは分離してください。

## Codex プラグイン

このリポジトリには Codex plugin manifest と bundled `quota-fuse` Skill も含まれます。Codex から quota / costs の確認、policy に沿った model 選択、Fuse policy を通した追加 OpenAI API call の dispatch ができます。

ただし、現在実行中の Codex turn 自体の model を差し替えるものではありません。Fuse が管理するのは、Codex が plugin-facing Python CLI 経由で明示的に dispatch する API call です。

ローカル marketplace への導入方法と使い方は [docs-ja/CODEX_PLUGIN.md](docs-ja/CODEX_PLUGIN.md) を参照してください。

## モデル選択

`run` の既定 quality は `auto` です。実行前に小さな difficulty classifier を無料 quota 内で実行し、通常タスクは `low`、難しいタスクは `high` に振り分けます。

    python3 python/openai_quota_fuse.py run "英訳して: おはよう"
    # quality: auto -> low

    python3 python/openai_quota_fuse.py run \
      "分散システムの移行方式を3案比較し、障害時の切り戻しまで含む段階的な移行計画を設計して"
    # quality: auto -> high

classifier は `gpt-5.6-luna` + low reasoning + Responses API の最小値である16 output tokens の小さな判定タスクです。classifier 自身についても `input_tokens + max_output_tokens` を無料 quota に予約できる場合だけ呼びます。input token の計数には `/responses/input_tokens` が受け付ける入力関連フィールドだけを送り、Responses API 本体だけの `max_output_tokens` は送りません。classifier が実行できない、または `low` / `high` 以外を返した場合は、有料判定へ fallback せず `low` を使います。

明示指定は自動判定より優先します。

    -q low   # classifier を呼ばず low 固定
    -q high  # classifier を呼ばず high 固定
    -m MODEL # classifier を呼ばず指定モデル固定

`select` は prompt を持たないため、自動難易度判定は行わず既定 `low` のままです。

`low` の無料候補順は:

    gpt-5.6-terra → gpt-5.6-luna → gpt-5.6-sol

Terra と Luna は high-volume の無料 token quota を共有するため、無料枠では quota token あたりの能力を優先して Terra を先にします。`high` は:

    gpt-5.6-sol → gpt-5.6-terra → gpt-5.6-luna

無料候補が保守的な予約量を確保できない場合だけ、年間有料予算を使えます。既定は `$5` です。

    OPENAI_ANNUAL_PAID_BUDGET_USD=5
    OPENAI_ANNUAL_PAID_BUDGET_USD=0   # 有料 fallback を無効化

通常の有料 fallback はドル単価を重視して無料枠とは別順序です。

    gpt-5.6-luna → gpt-5.6-terra → gpt-5.6-sol

年間上限の実支出の正本には Organization Costs API を使います。そのため、OpenAIQuotaFuse を通さず `curl` や別アプリから直接使った API 支出も、OpenAI 側で Costs に計上された後は次回の判定に含まれます。

ただし Costs への反映には遅延があり得るため、直近の QuotaFuse 有料実行についてはローカル ledger も保守的な lag guard として加算します。一時的に二重計上になる場合がありますが、`$5` を使い切ることより意図しない有料超過を避けることを優先します。

現在値は次で確認できます。

    python3 python/openai_quota_fuse.py costs
    python3 python/openai_quota_fuse.py costs -r

通常表示では `official_costs_usd`、直近の local guard、budget 判定に使う effective spend を分けて表示します。Costs API は 1月1日 00:00 UTC からページングして UTC 暦年全体を集計します。

プリペイド残高や個々の失効日時について、現時点で runtime 判定に使える信頼できる公式 API は確認できていないため、Billing UI のスクレイピングや推測はしません。購入済み credit は現在の OpenAI 公式説明では購入から1年で失効しますが、失効日は runtime model selection には使いません。

## `run`

推論前に `POST /v1/responses/input_tokens` で input token 数を取得し、次を予約します。

    input_tokens + max_output_tokens

`-o/--max-output-tokens` は現在の GPT-5.6 Responses API の範囲である 16〜128,000 tokens をローカルで検証します。範囲外の値は API を呼ぶ前に拒否します。

まず普通に質問する:

    python3 python/openai_quota_fuse.py run "富士山の高さは？"

入力方法を変える:

    python3 python/openai_quota_fuse.py run -i "HTTPの404と500の違いは？"
    printf '%s\n' "京都府の府庁所在地は？" | python3 python/openai_quota_fuse.py run
    python3 python/openai_quota_fuse.py run -i - < prompt.txt

モデル選択や推論量を明示する:

    python3 python/openai_quota_fuse.py run -q low "次の単語を英訳して: りんご"
    python3 python/openai_quota_fuse.py run -q high \
      "CAP定理の3要素と実システム設計上のトレードオフを具体例付きで説明して"
    python3 python/openai_quota_fuse.py run -m gpt-5.6-luna -o 256 \
      "TCPとUDPの違いを3点で説明して"
    python3 python/openai_quota_fuse.py run -e high \
      "12個の硬貨のうち1個だけ重さが異なる。天秤3回以内で特定する方法を考えて"

Responses API の完全な response JSON を確認する:

    python3 python/openai_quota_fuse.py run -r "富士山の高さは？"

### context

`-c/--context FILE` は UTF-8 text file を現在の user request の context として付加します。複数回指定できます。context を含めた実際の input 全体を token count してから quota 判定します。

    python3 python/openai_quota_fuse.py run \
      -c AGENTS.md \
      -c README.md \
      -c python/openai_quota_fuse.py \
      "この実装を設計レビューして、優先度の高い改善点を挙げて"

現時点では明示的な text file 指定だけを扱います。directory 再帰、glob、binary、OpenAI Files API / File Search は暗黙には使いません。

### session

`-s/--session NAME` を付けると、同じ名前で前回成功した Responses API の `response_id` をローカルへ保存し、次回の token count と本推論の両方に `previous_response_id` として渡します。これにより会話履歴を引き継げます。

    python3 python/openai_quota_fuse.py run -s design \
      -c python/openai_quota_fuse.py \
      "この実装を設計レビューして"

    python3 python/openai_quota_fuse.py run -s design \
      "さっきの指摘のうち優先度が高い3つを詳しく説明して"

session state は既定で `~/.local/state/openai-quota-fuse/sessions/` に置き、`OPENAI_QUOTA_FUSE_SESSION_DIR` で変更できます。保存するのは最新の response ID と更新時刻だけで、会話本文を QuotaFuse 側で複製保存しません。OpenAI 側で response が利用できなくなった場合、その session 継続も失敗します。

`-q/--quality` は `auto`、`low`、`high`。省略時は `auto` です。`-e/--effort` は Responses API の `reasoning.effort` を指定し、quality とは独立です。quality はモデル選択順、effort は選ばれたモデル内部の推論量を制御します。effort の指定可能値は `none`、`low`、`medium`、`high`、`xhigh`、`max`。省略時はモデル/API の既定値をそのまま使います。

`-r/--raw` では stdout に抽出済み text ではなく Responses API の完全な JSON を出します。classifier の判定、quota/model/usage の診断情報は stderr に出します。

正規の Python 実装は plain text input に加え、明示的な text context と named session を扱います。tools、structured output schema、images、任意の Responses API field を中途半端な generic proxy としては通しません。それらは quota/accounting 上の意味を定義してから追加します。

旧 positional 形式 `check MODEL TOKENS` と `select TOKENS [MODEL ...]` は 0.x の間は互換維持します。正規形は long/short option とし、positional 互換は 1.0 で削除予定です。

## 中身を確認したくなったら

    python3 python/openai_quota_fuse.py status
    python3 python/openai_quota_fuse.py costs
    python3 python/openai_quota_fuse.py models
    python3 python/openai_quota_fuse.py select -t 8000
    python3 python/openai_quota_fuse.py check -m gpt-5.6-sol -t 8000
    python3 python/openai_quota_fuse.py status -r

同等の Shell entry point は `./shell/openai-quota-fuse.sh` から引き続き利用できます。処理はそのまま Python CLI へ委譲されます。

## ポリシーと保守

無料枠の会計対象は `models.json`、無料・有料の自動選択方針と classifier 設定は `model-selection.json` に置きます。これらが古くなった場合は現在の OpenAI 一次資料を優先します。

incentive 固有の Usage API 挙動を検証し終えるまでは、正規実装は登録モデルの Usage をすべて消費として数えます。金額会計は Organization Costs を使います。モデルポリシーは `bash scripts/audit-model-policy.sh` と週次 workflow で監査します。

言語共通のポリシーは `spec/QUOTA_POLICY.md`、残作業は [docs-ja/TODO.md](docs-ja/TODO.md) を参照してください。
