# OpenAIQuotaFuse

[English](README.md) | 日本語

OpenAIQuotaFuse は、OpenAI API の無料トークン枠をできるだけ超えないようにして API を呼ぶための quota guard です。

通常は OpenAI API を直接呼ぶ代わりに OpenAIQuotaFuse を通します。

    直接呼ぶ:
    あなた → OpenAI API

    OpenAIQuotaFuse を使う:
    あなた → quota確認 → モデル選択 → OpenAI API

残り quota とモデル選択を毎回自分で考える必要を減らすことが目的です。

## まずこれだけ

やりたいことは単純です。

    OpenAI API を使いたい
            ↓
    OpenAIQuotaFuse
            ↓
       無料枠に収まる？
        ↓ YES   ↓ NO
       呼ぶ      止める

普段は `status` や `select` を自分で組み合わせる必要はありません。最初は `run` だけ覚えてください。

現在の判定は、無料枠を過大評価しないことを優先した安全側の判定です。実際に利用できる無料枠より早く停止する場合があります。

### 1. ダウンロード

    git clone https://github.com/oqzl/OpenAIQuotaFuse.git
    cd OpenAIQuotaFuse

必要なのは Bash、curl、jq です。

### 2. 2種類の API key を設定

    cp .env.example .env
    $EDITOR .env

`.env` に次の2つを設定します。

    OPENAI_ADMIN_KEY=...
    OPENAI_API_KEY=...

- `OPENAI_ADMIN_KEY`: 今日どれだけ使ったか調べるための Admin key
- `OPENAI_API_KEY`: 実際に AI を呼ぶための通常の API key

Admin key は Organization レベルの強い credential なので、通常の API key と分離してください。

### 3. AI を呼ぶ

    ./shell/openai-quota-fuse.sh run "富士山の高さは？"

これが基本形です。

OpenAIQuotaFuse は内部で、残り quota を確認し、利用可能なモデルを選び、Responses API を呼びます。無料 quota に収まるモデルがなければ API を呼ばずに停止します。

既定では軽量・低コスト側の `low` profile を使い、次の順で候補を試します。

    gpt-5.6-luna → gpt-5.6-terra → gpt-5.6-sol

出力イメージ:

    quota: OK (conservative estimate 1068 tokens)
    model: gpt-5.6-luna

    富士山の標高は3,776メートルです。

これで最初の一歩は完了です。

## 難しい仕事だけ high にする

普通の利用では `-q low` を指定する必要はありません。`low` が既定値です。

品質を優先したい仕事だけ `high` を明示します。

    ./shell/openai-quota-fuse.sh run -q high "この設計案の技術的な弱点を詳しくレビューして"

`high` では現在、次の順で候補を試します。

    gpt-5.6-sol → gpt-5.6-luna → gpt-5.6-terra

モデルを自分で固定する場合:

    ./shell/openai-quota-fuse.sh run -m gpt-5.6-luna "1+1は？"

最大出力を小さくする場合:

    ./shell/openai-quota-fuse.sh run -o 256 "一言で説明して"

`run` は現在、入力サイズを安全側にローカル概算し、`max-output-tokens` と合わせて必要 quota を見積もります。これは厳密な tokenizer ではありません。公式 API から input token 数を取得する方式への置き換えは TODO として管理しています。

## 中身を確認したくなったら

普段は `run` だけで構いません。以下は quota の状態や選択結果を自分で確認したいときの道具です。

    # 今日の残りを見る
    ./shell/openai-quota-fuse.sh status

    # 対象モデルと選択プロファイルを見る
    ./shell/openai-quota-fuse.sh models

    # 8000トークン必要だと仮定してモデルを選ぶ
    ./shell/openai-quota-fuse.sh select -t 8000

    # 特定モデルで8000トークン使えるか確認する
    ./shell/openai-quota-fuse.sh check -m gpt-5.6-sol -t 8000

Usage API の生レスポンスを見る場合:

    ./shell/openai-quota-fuse.sh status -r

## 仕組み

OpenAI の無料対象モデルと quota group の上限は時間とともに変わるため、各実装へハードコードせず、共通の機械可読レジストリ `models.json` に集約します。`models.json` は無料枠の会計対象を広く保持し、自動選択で実際に使う候補は `model-selection.json` に分離します。

quota group は無料 quota の容量分類です。モデル品質やタスク難易度の profile ではありません。

現在の Shell 実装は、`models.json` に登録されたモデルに対する当日の Usage をすべて quota 消費として数えます。実際の incentive 適用量より残量を少なく見積もる可能性はありますが、無料残量を過大評価しないことを優先します。

## モデルポリシーの定期監査

    bash scripts/audit-model-policy.sh

`.github/workflows/model-policy-audit.yml` でも毎週監査します。`model-selection.json` の既定レビュー間隔は30日です。

言語共通のポリシーは `spec/QUOTA_POLICY.md`、今後の実装項目は [docs-ja/TODO.md](docs-ja/TODO.md) を参照してください。
