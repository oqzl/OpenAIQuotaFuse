# TODO

[English](../docs/TODO.md)

この文書は、PR #1 で Shell MVP と共通 quota policy を整備した後に残った実装項目を管理する。

## P0 — Shell CLI の使い勝手と選択ポリシー

- [x] `models.json` は広い会計対象レジストリ、`model-selection.json` は絞り込んだ自動選択ポリシーとして分離する。
- [x] `check` と `select` に明示的な long option と short alias を追加し、既存の位置引数形式も互換性のため維持する。
- [x] Shell CLI で `--model/-m`、`--estimated-tokens/-t` を扱えるようにする。
- [x] 無料 quota group とモデル品質・タスク難易度の概念を分離する。quota group は容量・会計だけを表す。
- [ ] 軽いタスクで安価なモデルを選ぶため、呼び出し側が指定する別の task/quality hint が有用か検討する。追加する場合は無料 quota group と混同しない語彙を使い、判定のための追加推論は行わない。
- [ ] 旧形式の `check MODEL TOKENS` と `select TOKENS [MODEL ...]` を将来 Deprecated にするか判断する。

## P0 — `run` の E2E フロー

- [ ] 主たるユーザー向けコマンドとして `run` を追加する。
- [ ] 実際のリクエストを `--input/-i` で受け取り、パイプ利用向けに stdin も扱う。
- [ ] 通常推論用 `OPENAI_API_KEY` と Organization Usage API 用 `OPENAI_ADMIN_KEY` を分離する。
- [ ] `OPENAI_ADMIN_KEY` は OpenAI Platform の Organization の Admin Keys 画面で作成し、管理・Usage API 用だけに使うことを文書化する。
- [ ] `POST /responses/input_tokens` で input token 数を取得し、API が正本値を返せる場合はローカル推定を使わない。
- [ ] 推論前に `input_tokens + max_output_tokens` を予約する。`max_output_tokens` は可視出力と reasoning token の双方を含む。
- [ ] 保守的な予約量を収容できる quota group の最初の候補モデルを選ぶ。
- [ ] quota check 成功後にのみ Responses API を実行する。
- [ ] 実レスポンスの `usage.input_tokens`、`usage.output_tokens`、`usage.total_tokens` を診断情報として公開する。
- [ ] `run` に `--max-output-tokens/-o`、`--raw/-r`、`--input/-i`、`--model/-m` を追加する。
- [ ] tools、structured output、files/images、previous response 等をどこまで受けるか定義する。Shell リファレンス実装を汎用 API wrapper にしすぎない。

## P1 — 会計ロジックの実環境検証

- [x] 実 Admin API key で、Usage 0 のケースについて `status --raw` をライブ検証した。日次 bucket が期待通り `results: []` を返すことを確認済み。
- [ ] API billing を有効化した後、実推論を1回行い、その Usage API record を確認する。
- [ ] 実際の `service_tier` を確認し、Usage API だけで incentive 対象トラフィックを十分確実に識別できるか判断する。
- [ ] 検証が終わるまでは、登録済み対象モデルの Usage をすべて消費として数え、無料残量を過大評価しない。
- [ ] secret や organization identifier を除去した Usage API レスポンス例を記録する。

## P1 — 期限付きプリペイドクレジット

- [ ] API の購入済み prepaid credit を、日次無料 token quota とは別の予算として扱う。OpenAI の現行仕様では最低購入額は $5、購入済み credit は1年で失効する。
- [ ] prepaid credit の残高、個々の grant/購入の有効期限、またはそれらを確実に導出できる billing data を公式 API から取得できるか調査する。実行時ポリシーのために Billing UI をスクレイピングしない。
- [ ] 残高と有効期限を確実に取得できる場合、失効する credit を捨てる代わりに期限前に計画的に消費する optional な credit burn-down policy を設計する。
- [ ] burn-down は opt-in かつ上限付きとする。prepaid credit が存在するという理由だけで有料利用を暗黙に許可しない。
- [ ] 有効期限が異なる複数の credit grant/購入がある場合、および OpenAI が明記する billing 反映遅延・negative balance の可能性をどう扱うか定義する。
- [ ] 有効期限を公式 API から取得できない場合、推測せず、残 prepaid budget と expiry date をユーザー設定として明示的に与える方式を検討する。

## P1 — モデルポリシー保守

- [ ] policy audit の期限切れごとに incentive 対象、quota group、availability/deprecation、API pricing を再確認する。
- [ ] 自動選択候補ごとに、同じ quota group の新モデルに対して残す理由がまだあるか評価する。
- [ ] 自動選択から外した古い active model も、対象である限り会計レジストリには残す。
- [ ] 全自動選択候補が `models.json` に存在することをテストする。
- [ ] 定期監査を実質的に改善する場合に限り、選択理由や単価メタデータの機械可読化を検討する。

## P1 — テスト

- [ ] Usage API レスポンスを mock した Shell テストを追加する。
- [ ] UTC 日次リセット、tier 1–2 / tier 3–5、reserve 計算、未知モデル、quota 枯渇、候補フォールバックを網羅する。
- [ ] long/short alias と明示的な候補順指定をテストする。
- [ ] `run` を既定経路として文書化する前に、input-token counting と `run` の mock テストを追加する。
- [ ] 期限付き prepaid credit を実装する場合、既定OFF、有効期限境界、予算上限、billing metadata を取得できない場合を含む burn-down policy のテストを追加する。
- [ ] 将来の Python / Swift 実装でも同じ policy fixture を利用する。

## P2 — Python 3 実装

- [ ] `spec/QUOTA_POLICY.md` の言語非依存ポリシーを実装する。
- [ ] model/quota データを複製せず、`models.json` と `model-selection.json` を共有する。
- [ ] 有用な範囲で Shell と exit/error semantics を揃えつつ、Python API としては自然な形にする。
- [ ] 同じ保守的な `run` 予約方式を実装する。

## P2 — Swift 6 実装

- [ ] 同一 quota policy を実装する Swift Package を追加する。
- [ ] 機械可読レジストリを共有するか、そこから strongly typed data を生成する。
- [ ] networking と policy logic を分離し、各アプリが独自 UI を持てるようにする。
- [ ] 同じ保守的予約方式を実装する。

## 設計上の制約

- 原則として、無料枠利用率の最大化より意図しない有料利用の回避を優先する。ただし、呼び出し側が上限付き prepaid-credit burn-down policy を明示的に有効化した場合は例外とする。
- モデル選択のためだけに推論を1回追加してはならない。
- 無料 quota group をモデル品質やタスク難易度の profile として表現しない。
- 最新の OpenAI 一次資料と実 API の観測結果を、古いリポジトリ上の仮定より優先する。
- 言語非依存の挙動は `spec/QUOTA_POLICY.md` を正本とする。
